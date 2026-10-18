import ScreenSaver
import AVFoundation
import Cocoa
import CoreMedia
import CoreVideo

// ============================================================
//  WallLocusSaverView — 屏保渲染视图
//
//  运行环境：legacyScreenSaver.appex 沙盒进程
//  配置来源：SharedConfig（UserDefaults suite）
//  渲染方式：AVPlayerLayer 硬件解码，与主 App 一致
// ============================================================

final class WallLocusSaverView: ScreenSaverView {

    private let playerLayer = AVPlayerLayer()
    private let imageLayer = CALayer()
    private let messageLayer = CATextLayer()

    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?
    private var mediaSize: CGSize = .zero
    private var adjustment = Adjustment()

    // MARK: - 生命周期

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setupLayers()
        loadMedia()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
        loadMedia()
    }

    deinit {
        stopMedia()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        imageLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)

        playerLayer.videoGravity = .resize
        playerLayer.isHidden = true
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)

        messageLayer.string = ""
        messageLayer.fontSize = 15
        messageLayer.alignmentMode = .center
        messageLayer.foregroundColor = NSColor(white: 0.55, alpha: 1).cgColor
        messageLayer.isHidden = true
        layer?.addSublayer(messageLayer)
    }

    // MARK: - 载入素材

    private func loadMedia() {
        guard let snapshot = SharedConfig.load() else {
            showMessage("Open WallLocus and choose a wallpaper")
            return
        }
        adjustment = snapshot.adjustment

        let path = snapshot.mediaPath
        guard FileManager.default.fileExists(atPath: path) else {
            showMessage("Wallpaper file not found")
            return
        }

        if Rendering.isImagePath(path) {
            loadImage(path: path)
        } else {
            loadVideo(path: path, muted: snapshot.muted)
        }
    }

    private func loadImage(path: String) {
        guard let cg = Self.downsample(path: path, to: bounds.size) else {
            showMessage("Cannot load image")
            return
        }
        mediaSize = CGSize(width: cg.width, height: cg.height)
        imageLayer.contents = cg
        imageLayer.isHidden = false
        playerLayer.isHidden = true
        messageLayer.isHidden = true
        layoutLayers()
    }

    private func loadVideo(path: String, muted: Bool) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        item.preferredForwardBufferDuration = 0.2
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        p.actionAtItemEnd = .none
        p.preventsDisplaySleepDuringVideoPlayback = false

        // 循环：播完回到起点
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            p.seek(to: .zero)
            p.play()
        }

        playerLayer.player = p
        playerLayer.isHidden = false
        imageLayer.isHidden = true
        messageLayer.isHidden = true
        player = p

        // 异步取视频尺寸
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        Task { [weak self] in
            var size = CGSize.zero
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let t = natural.applying(transform)
                size = CGSize(width: abs(t.width), height: abs(t.height))
            }
            let resolved = size
            await MainActor.run {
                guard let self else { return }
                self.mediaSize = resolved
                self.layoutLayers()
            }
        }
    }

    private func showMessage(_ text: String) {
        messageLayer.string = text
        messageLayer.isHidden = false
        imageLayer.isHidden = true
        playerLayer.isHidden = true
        layoutLayers()
    }

    private func stopMedia() {
        player?.pause()
        if let o = loopObserver {
            NotificationCenter.default.removeObserver(o)
            loopObserver = nil
        }
        playerLayer.player = nil
        player = nil
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }

        let frame = Rendering.layerFrame(bounds: b,
                                         mediaSize: mediaSize,
                                         adjustment: adjustment)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = frame
        imageLayer.frame = frame
        messageLayer.frame = CGRect(x: 0, y: b.midY - 10, width: b.width, height: 20)
        CATransaction.commit()
    }

    // MARK: - 动画控制

    override func startAnimation() {
        super.startAnimation()
        if let p = player {
            p.seek(to: .zero)
            p.play()
        }
        layoutLayers()
    }

    override func stopAnimation() {
        super.stopAnimation()
        player?.pause()
    }

    override func animateOneFrame() {
        // 图层 frame 在尺寸变化时才需重算；这里保持轻量
    }

    override var isOpaque: Bool { true }
    override var hasConfigureSheet: Bool { false }

    // MARK: - 图片降采样（与主 App 同策略）

    private static func downsample(path: String, to size: CGSize) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let maxPixel = max(size.width, size.height) * 2   // 预留 Retina
        guard maxPixel > 1 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
