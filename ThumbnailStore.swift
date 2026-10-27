import Foundation
import AppKit
import ImageIO
import AVFoundation
import CoreMedia

// ============================================================
//  ThumbnailStore — 壁纸库缩略图（独立于全尺寸壁纸缓存）
//
//  为什么不复用 WallpaperManager.imageCache：
//    那边缓存的是铺满整块屏的位图（长边可达 4K、单张 20MB+），
//    只为「正在显示的壁纸」服务，且会被按需裁掉。
//    库里的缩略图是「一眼看构图」用的，长边 160px、单张约 75KB，
//    生命周期与全屏壁纸完全不同，混在一起会让两边的淘汰策略互相干扰。
//
//  线程模型：
//    解码全部在私有并发队列上完成，completion 统一切回主线程。
//    同一个路径的并发请求会合并成一次解码（inFlight 去重）。
// ============================================================

final class ThumbnailStore {

    static let shared = ThumbnailStore()

    /// 缩略图长边像素。112×70 的展示框在 2x 屏上需要 224px，
    /// 但 160px 已足够「看清构图」，且内存只有 224px 的一半。
    static let maxPixel: CGFloat = 160

    /// 包一层，避免直接把 CF 类型塞进 NSCache 的桥接歧义
    private final class Box {
        let image: CGImage
        var cost: Int { image.bytesPerRow * image.height }
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let queue = DispatchQueue(label: "app.walllocus.thumbnails",
                                      qos: .utility,
                                      attributes: .concurrent)
    private let lock = NSLock()
    /// 正在进行中的请求：路径 -> 待回调列表
    private var inFlight: [String: [(CGImage?) -> Void]] = [:]

    private init() {
        // 100 张 × 约 75KB ≈ 7.5MB，再设 16MB 硬上限兜底
        cache.countLimit = 100
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    // MARK: - 查询

    /// 同步取已缓存的缩略图（不触发解码）。UI 复用时先用它填，避免闪烁。
    func cachedImage(for path: String) -> CGImage? {
        cache.object(forKey: path as NSString)?.image
    }

    /// 异步取缩略图。已缓存则同步回调；否则后台生成。
    /// completion 保证在主线程调用；失败时传 nil，由调用方显示占位图。
    func thumbnail(for path: String,
                   completion: @escaping (CGImage?) -> Void) {
        if let hit = cachedImage(for: path) {
            DispatchQueue.main.async { completion(hit) }
            return
        }

        lock.lock()
        if inFlight[path] != nil {
            // 已有同路径请求在跑，挂上去等结果，避免重复解码
            inFlight[path]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[path] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            // 类型由扩展名推断，避免依赖 main.swift 里的 MediaKind
            let image: CGImage? = Rendering.isImagePath(path)
                ? Self.makeImageThumbnail(path: path)
                : Self.makeVideoThumbnail(path: path)
            if let image {
                let box = Box(image)
                self.cache.setObject(box, forKey: path as NSString, cost: box.cost)
            }

            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: path) ?? []
            self.lock.unlock()

            DispatchQueue.main.async {
                for cb in waiting { cb(image) }
            }
        }
    }

    // MARK: - 缓存维护

    func remove(for path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// 仅用于测试与诊断
    var cachedCount: Int {
        // NSCache 不暴露条目数，这里只用于确认「有没有命中」
        cache.object(forKey: "__probe__" as NSString) == nil ? 0 : 1
    }

    // MARK: - 图片

    private static func makeImageThumbnail(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - 视频

    private static func makeVideoThumbnail(path: String) -> CGImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))

        // 同步取时长与轨道；抽帧本身也是同步 API，但整段都在后台队列
        let sem = DispatchSemaphore(value: 0)
        var durationSeconds: Double = 0
        var hasVideoTrack = false

        Task {
            if let d = try? await asset.load(.duration) {
                durationSeconds = CMTimeGetSeconds(d)
            }
            if let tracks = try? await asset.loadTracks(withMediaType: .video) {
                hasVideoTrack = !tracks.isEmpty
            }
            sem.signal()
        }
        sem.wait()

        guard hasVideoTrack, durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // 允许一定误差，避免为了精确帧而解整段
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        // 取 10% 处（避开片头黑场），最长不超过 1 秒
        let t = min(1.0, durationSeconds * 0.1)
        let time = CMTime(seconds: max(0, t), preferredTimescale: 600)

        let gsem = DispatchSemaphore(value: 0)
        var result: CGImage?
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            result = image
            gsem.signal()
        }
        gsem.wait()
        return result
    }
}
