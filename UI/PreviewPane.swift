import AppKit
import AVFoundation
import CoreMedia

// ============================================================
//  PreviewPane — 右栏顶部的当前素材大图预览
//
//  用 ThumbnailStore 取一张更大的缩略图（长边 480）单独缓存，
//  与卡片用的 160px 缓存分开：大图只用于这一处，不该挤占卡片缓存的名额。
// ============================================================

final class PreviewPane: NSView {

    /// 预览图长边。右栏宽 270，2x 屏需要 540，取 480 略省一点内存。
    static let previewMaxPixel: CGFloat = 480

    /// 与网格卡片一致的「按图片实际矩形裁圆角」视图
    private let imageView = RoundedImageView()
    /// 包住图片的圆角容器
    private let clipBox = NSView()

    private let placeholder = NSTextField(labelWithString: "")
    private var currentPath: String?
    private var requestToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        // 预览图圆角（比之前大一些，与卡片风格一致）
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        // 底色透明：图片自己就是内容，不需要「相框」
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0

        // 用容器包住图片：容器设圆角 + masksToBounds 是最可靠的裁切方式。
        // 直接给 NSImageView 设圆角/mask 都不生效 —— 图片走内部绘制路径。
        clipBox.wantsLayer = true
        clipBox.layer?.masksToBounds = true
        clipBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipBox)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.cornerRadius = 12
        imageView.translatesAutoresizingMaskIntoConstraints = false
        clipBox.addSubview(imageView)

        placeholder.font = NSFont.systemFont(ofSize: 11)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        NSLayoutConstraint.activate([
            clipBox.topAnchor.constraint(equalTo: topAnchor),
            clipBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipBox.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: clipBox.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: clipBox.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: clipBox.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: clipBox.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: widthAnchor, constant: -20),
        ])
    }

    /// 显示某个素材的预览；传 nil 显示占位文案
    func show(path: String?, fallbackText: String) {
        currentPath = path
        requestToken += 1
        let token = requestToken

        guard let path else {
            imageView.image = nil
            placeholder.stringValue = fallbackText
            placeholder.isHidden = false
            return
        }

        // 先用已有缓存立刻填，避免闪烁
        if let hit = PreviewCache.shared.cached(path: path) {
            imageView.image = NSImage(cgImage: hit,
                                      size: NSSize(width: hit.width, height: hit.height))
            placeholder.isHidden = true
        } else {
            imageView.image = nil
            placeholder.stringValue = ""
            placeholder.isHidden = true
        }

        PreviewCache.shared.image(for: path) { [weak self] image in
            guard let self, self.requestToken == token else { return }
            guard let image else {
                self.placeholder.stringValue = fallbackText
                self.placeholder.isHidden = false
                return
            }
            self.imageView.image = NSImage(cgImage: image,
                                           size: NSSize(width: image.width, height: image.height))
            self.placeholder.isHidden = true
        }
    }
}

// ============================================================
//  PreviewCache — 预览大图独立缓存
//
//  为什么不复用 ThumbnailStore：那边是 160px、上限 16MB，
//  服务网格里几十张卡片。预览只要一张，但需要更大的分辨率，
//  混在一起会让卡片缓存被频繁挤掉，切换素材时又得重解码。
// ============================================================

final class PreviewCache {

    static let shared = PreviewCache()

    private final class Box {
        let image: CGImage
        var cost: Int { image.bytesPerRow * image.height }
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let queue = DispatchQueue(label: "app.walllocus.preview",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight: [String: [(CGImage?) -> Void]] = [:]

    private init() {
        // 只留最近几张；预览一次只看一个
        cache.countLimit = 6
        // 只留 6 张，按 480px 长边算 6 张约 5MB；
        // 48MB 相当于允许 50 张，与 countLimit 矛盾且白占内存。
        cache.totalCostLimit = 12 * 1024 * 1024
    }

    func cached(path: String) -> CGImage? {
        cache.object(forKey: path as NSString)?.image
    }

    func image(for path: String, completion: @escaping (CGImage?) -> Void) {
        if let hit = cached(path: path) {
            DispatchQueue.main.async { completion(hit) }
            return
        }

        lock.lock()
        if inFlight[path] != nil {
            inFlight[path]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[path] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let image = Self.decode(path: path)
            if let image {
                let box = Box(image)
                self.cache.setObject(box, forKey: path as NSString, cost: box.cost)
            }
            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: path) ?? []
            self.lock.unlock()
            DispatchQueue.main.async { for cb in waiting { cb(image) } }
        }
    }

    func clear() { cache.removeAllObjects() }

    private static func decode(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if Rendering.isImagePath(path) {
            guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: PreviewPane.previewMaxPixel
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }

        // 视频：抽一帧（与卡片缩略图同策略，但用更大尺寸）
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let sem = DispatchSemaphore(value: 0)
        var duration: Double = 0
        var hasVideo = false
        Task {
            if let d = try? await asset.load(.duration) {
                duration = CMTimeGetSeconds(d)
            }
            if let t = try? await asset.loadTracks(withMediaType: .video) {
                hasVideo = !t.isEmpty
            }
            sem.signal()
        }
        sem.wait()
        guard hasVideo, duration.isFinite, duration > 0 else { return nil }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: PreviewPane.previewMaxPixel,
                                 height: PreviewPane.previewMaxPixel)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let t = CMTime(seconds: max(0, min(1.0, duration * 0.1)), preferredTimescale: 600)

        let gsem = DispatchSemaphore(value: 0)
        var result: CGImage?
        gen.generateCGImageAsynchronously(for: t) { img, _, _ in
            result = img
            gsem.signal()
        }
        gsem.wait()
        return result
    }
}
