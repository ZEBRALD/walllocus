import Cocoa
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

// ============================================================
//  WallLocus
//  Remember every wallpaper's placement on every display.
//
//  极简 macOS 视频 / 图片壁纸
//  多显示器 · 每屏独立素材 · 填充/适应/拉伸 · 自由缩放与位置
//  ★ 调整量按「显示器 × 壁纸」双维度分别记忆
//
//  MIT License
// ============================================================

// MARK: - 模型

// ScaleMode 定义在 Rendering.swift（与屏保共用），这里只加界面用的本地化标签
extension ScaleMode {
    var label: String {
        switch self {
        case .fill: return L10n.t("mode.fill")
        case .fit: return L10n.t("mode.fit")
        case .stretch: return L10n.t("mode.stretch")
        }
    }
}

enum MediaKind: String, Codable {
    case video, image

    static func detect(_ path: String) -> MediaKind {
        Rendering.isImagePath(path) ? .image : .video
    }

    var label: String { self == .video ? L10n.t("kind.video") : L10n.t("kind.image") }
}

struct LibraryItem: Codable, Equatable {
    var path: String
    var kind: MediaKind
    var name: String { (path as NSString).lastPathComponent }
}

struct AppState: Codable {
    var library: [LibraryItem] = []
    /// 显示器 UUID -> 该屏当前使用的项目路径
    var assignment: [String: String] = [:]
    /// 显示器 UUID -> 项目路径 -> 调整量（双维度记忆）
    var adjustments: [String: [String: Adjustment]] = [:]
    var muted: Bool = true
    /// 上次在壁纸库里选中的素材路径（重启后自动恢复）
    var lastSelectedItem: String? = nil

    func adjustment(display: String, item: String) -> Adjustment {
        adjustments[display]?[item] ?? Adjustment()
    }

    mutating func setAdjustment(_ adj: Adjustment, display: String, item: String) {
        var perItem = adjustments[display] ?? [:]
        perItem[item] = adj
        adjustments[display] = perItem
    }

    func item(for path: String) -> LibraryItem? { library.first { $0.path == path } }
}

final class StateStore {
    static let shared = StateStore()
    private let key = "walllocus.state.v1"
    private(set) var state = AppState()

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            state = decoded
        }
    }

    func update(_ body: (inout AppState) -> Void) {
        body(&state)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 屏幕工具

func screenID(_ screen: NSScreen) -> String {
    if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
        let did = CGDirectDisplayID(n.uint32Value)
        if let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, cf) as String
        }
        return "display-\(did)"
    }
    return "screen-\(Int(screen.frame.origin.x))-\(Int(screen.frame.origin.y))"
}

func screenTitle(_ screen: NSScreen) -> String {
    var name = screen.localizedName
    if screen == NSScreen.main { name += L10n.t("common.mainScreen") }
    return name + "  \(Int(screen.frame.width))×\(Int(screen.frame.height))"
}

// MARK: - 渲染视图

final class WallpaperView: NSView {
    private let playerLayer = AVPlayerLayer()
    private let imageLayer = CALayer()

    /// 渲染用目标像素尺寸（屏尺寸 × 2 倍屏），图片按此降采样以省内存
    var targetPixelSize: CGSize = .zero

    /// 素材原始像素尺寸
    var mediaSize: CGSize = .zero { didSet { layoutMedia() } }
    var kind: MediaKind = .video { didSet { layoutMedia() } }
    /// 当前生效的调整量（由管理器按 屏×项目 查出后灌入）
    var adjustment = Adjustment() { didSet { layoutMedia() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.isHidden = true
        imageLayer.contentsGravity = .resize
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var videoLayer: AVPlayerLayer { playerLayer }

    func showImage(_ image: CGImage, size: CGSize) {
        playerLayer.isHidden = true
        playerLayer.player = nil          // 切到图片时立刻释放视频解码器
        imageLayer.isHidden = false
        imageLayer.contents = image
        imageLayer.contentsScale = 1      // 位图已按目标尺寸生成，避免 CoreAnimation 再放大
        mediaSize = size
    }

    func showVideo(_ player: AVPlayer) {
        imageLayer.isHidden = true
        imageLayer.contents = nil         // 切到视频时释放图片位图
        playerLayer.isHidden = false
        playerLayer.player = player
        // 背景视频不参与交互，关闭隐式动画避免额外合成
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.removeAllAnimations()
        CATransaction.commit()
    }

    func clearMedia() {
        playerLayer.player = nil
        playerLayer.isHidden = true
        imageLayer.contents = nil
        imageLayer.isHidden = true
        mediaSize = .zero
    }

    override func layout() {
        super.layout()
        layoutMedia()
    }

    func layoutMedia() {
        // 布局算法与屏保共用，见 Rendering.swift
        applyFrame(Rendering.layerFrame(bounds: bounds,
                                        mediaSize: mediaSize,
                                        adjustment: adjustment))
    }

    private func applyFrame(_ r: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = r
        imageLayer.frame = r
        CATransaction.commit()
    }
}

// MARK: - 设置项（UserDefaults 持久化）

enum Settings {
    private static let d = UserDefaults.standard

    /// 全屏应用覆盖该屏时暂停壁纸
    static var pauseOnFullscreen: Bool {
        get { d.object(forKey: "pauseOnFullscreen") as? Bool ?? true }
        set { d.set(newValue, forKey: "pauseOnFullscreen") }
    }

    /// 电池供电时暂停壁纸
    static var pauseOnBattery: Bool {
        get { d.bool(forKey: "pauseOnBattery") }
        set { d.set(newValue, forKey: "pauseOnBattery") }
    }

    // 关窗后隐藏 Dock 图标：固定行为，不提供开关
}

// MARK: - 全屏监听

/// 检测哪些显示器正被全屏应用完整覆盖。
/// 全屏时壁纸被挡得严严实实，继续解码纯属浪费电，因此对这些屏暂停播放。
final class FullscreenMonitor {
    static let shared = FullscreenMonitor()

    /// 覆盖率达到这个比例才认定「全屏」（排除普通最大化窗口：它会让开菜单栏与 Dock）
    private let coverageThreshold: CGFloat = 0.96

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var last: Set<String> = []

    /// 每次全屏状态变化时回调（参数为当前处于全屏的显示器 ID 集合）
    var onChange: ((Set<String>) -> Void)?

    /// 用户可在菜单栏关掉该功能（持久化到 Settings）
    var isEnabled: Bool {
        get { Settings.pauseOnFullscreen }
        set {
            Settings.pauseOnFullscreen = newValue
            if newValue { check() } else { publish([]) }
        }
    }

    func start() {
        // 全屏应用活在独立的 Space 里，切 Space 是判断全屏变化最及时的时机
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck()
        })
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.check()
        }
        t.tolerance = 0.5              // 允许系统攒批触发，省电
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    /// 切 Space 后界面还没稳定，稍等一下再看
    private func scheduleCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.check()
        }
    }

    func check() {
        guard isEnabled else { return }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var covered: Set<String> = []

        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            // 窗口列表用的是 Quartz 全局坐标，屏幕范围也取同一坐标系
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
            let area = displayBounds.width * displayBounds.height
            guard area > 0 else { continue }

            for w in list {
                // 只看普通窗口层：菜单栏(24)、Dock(20)、桌面层等都是别的层
                guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
                guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
                guard let bd = w[kCGWindowBounds as String] as? [String: Any] else { continue }

                func v(_ k: String) -> CGFloat {
                    (bd[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                }
                let rect = CGRect(x: v("X"), y: v("Y"), width: v("Width"), height: v("Height"))
                let inter = rect.intersection(displayBounds)
                guard !inter.isNull else { continue }
                if (inter.width * inter.height) / area >= coverageThreshold {
                    covered.insert(screenID(screen))
                    break
                }
            }
        }
        publish(covered)
    }

    private func publish(_ set: Set<String>) {
        // 无显示器时不要让空集合反复触发
        guard set != last else { return }
        last = set
        onChange?(set)
    }
}

// MARK: - 壁纸管理

final class WallpaperManager {
    static let shared = WallpaperManager()

    final class Entry {
        let window: NSWindow
        let view: WallpaperView
        var player: AVPlayer?
        var path: String?
        init(window: NSWindow, view: WallpaperView) {
            self.window = window
            self.view = view
        }
    }

    private var entries: [String: Entry] = [:]
    private var loopTokens: [String: NSObjectProtocol] = [:]
    /// 图片缓存：按「路径 + 目标像素尺寸」为键，避免不同屏共用一张大图
    private var imageCache: [String: (CGImage, CGSize)] = [:]
    private let imageCacheLimit = 4
    private var imageCacheOrder: [String] = []
    private(set) var isPaused = false
    /// 正被全屏应用完整覆盖的显示器（这些屏上的壁纸暂停渲染）
    private var fullscreenDisplays: Set<String> = []

    /// 全屏状态变化：只处理受影响的显示器，避免全量重建播放器
    func updateFullscreen(_ covered: Set<String>) {
        let changed = covered.symmetricDifference(fullscreenDisplays)
        guard !changed.isEmpty else { return }
        fullscreenDisplays = covered
        for id in changed {
            guard let entry = entries[id] else { continue }
            if covered.contains(id) {
                entry.player?.pause()
            } else if !isPaused {
                entry.player?.play()
            }
        }
        if covered.isEmpty { releaseFreeMemory() }
    }

    /// 该显示器此刻是否应该播放
    private func shouldPlay(_ id: String) -> Bool {
        !isPaused && !fullscreenDisplays.contains(id)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        for (id, entry) in entries {
            if shouldPlay(id) { entry.player?.play() } else { entry.player?.pause() }
        }
        if paused {
            // 暂停时把图片缓存也放掉（恢复播放会重新按需加载），并立即归还空闲页
            imageCache.removeAll()
            imageCacheOrder.removeAll()
            releaseFreeMemory()
        } else {
            applyAll()
        }
    }

    func applyAll() {
        let state = StateStore.shared.state
        let screens = NSScreen.screens
        var alive = Set<String>()
        for screen in screens {
            let id = screenID(screen)
            alive.insert(id)
            guard let path = state.assignment[id],
                  FileManager.default.fileExists(atPath: path) else {
                remove(id)
                continue
            }
            let adj = state.adjustment(display: id, item: path)
            apply(path: path, adj: adj, muted: state.muted, screen: screen, id: id)
        }
        for id in Array(entries.keys) where !alive.contains(id) { remove(id) }
    }

    private func apply(path: String, adj: Adjustment, muted: Bool, screen: NSScreen, id: String) {
        let entry = entries[id] ?? makeEntry(screen: screen)
        if entry.window.frame != screen.frame {
            entry.window.setFrame(screen.frame, display: true)
        }
        entry.view.adjustment = adj
        // 目标像素尺寸：取屏幕物理像素的一半即可（Retina 下肉眼无损），
        // 位图内存随面积按平方下降 —— 相比直接用物理像素可省约 75%
        let scale = screen.backingScaleFactor
        let supersample: CGFloat = 0.5
        let target = CGSize(width: max(256, screen.frame.width * scale * supersample),
                            height: max(256, screen.frame.height * scale * supersample))
        entry.view.targetPixelSize = target
        let kind = MediaKind.detect(path)

        if entry.path != path {
            teardownMedia(entry, id: id)
            entry.path = path
            entry.view.kind = kind
            if kind == .video {
                setupVideo(entry, path: path, muted: muted, id: id)
            } else {
                setupImage(entry, path: path, target: target)
            }
        } else if kind == .video {
            entry.player?.isMuted = muted
            if let pl = entry.player, pl.rate == 0, shouldPlay(id) { pl.play() }
        }
        // 只在窗口不可见时置前，避免每次调参都重复打扰窗口服务器
        if !entry.window.isVisible {
            entry.window.orderFrontRegardless()
        }
    }

    func remove(_ id: String) {
        guard let e = entries[id] else { return }
        teardownMedia(e, id: id)
        e.window.orderOut(nil)
        entries[id] = nil
    }

    func stopAll() {
        for id in Array(entries.keys) { remove(id) }
        purgeCaches()
    }

    private func teardownMedia(_ entry: Entry, id: String) {
        entry.player?.pause()
        entry.view.clearMedia()
        entry.player = nil
        entry.path = nil
        if let t = loopTokens[id] {
            NotificationCenter.default.removeObserver(t)
            loopTokens[id] = nil
        }
    }

    private func makeEntry(screen: NSScreen) -> Entry {
        let id = screenID(screen)
        let w = NSWindow(contentRect: screen.frame,
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false,
                         screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        let v = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        let e = Entry(window: w, view: v)
        entries[id] = e
        return e
    }

    private func setupVideo(_ entry: Entry, path: String, muted: Bool, id: String) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        // 降低解码与缓冲开销：只保留回放所需能力
        item.preferredForwardBufferDuration = 0.2
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item.automaticallyPreservesTimeOffsetFromLive = false
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        // 壁纸不需要音频管线与音视频同步信息展示
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.defaultRate = 1.0
        entry.view.showVideo(player)
        entry.view.mediaSize = .zero
        let token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            player.seek(to: CMTime.zero)
            player.play()
        }
        loopTokens[id] = token
        entry.player = player
        loadVideoSize(URL(fileURLWithPath: path)) { [weak entry] size in
            entry?.view.mediaSize = size
        }
        if shouldPlay(id) { player.play() }
    }

    private func setupImage(_ entry: Entry, path: String, target: CGSize) {
        let key = "\(path)@\(Int(target.width))x\(Int(target.height))"
        if let cached = imageCache[key] {
            entry.view.showImage(cached.0, size: cached.1)
            touchCache(key)
            return
        }
        guard let cg = Self.downsample(path: path, to: target) else {
            entry.view.clearMedia()
            return
        }
        let size = CGSize(width: cg.width, height: cg.height)
        imageCache[key] = (cg, size)
        touchCache(key)
        entry.view.showImage(cg, size: size)
    }

    /// 把图片解码并降采样到不超过 target 的尺寸（用 ImageIO 直接出图，跳过 NSImage，
    /// 内存峰值只占降采样后的位图，不产生原图整幅位图）
    static func downsample(path: String, to target: CGSize) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let maxPixel = max(target.width, target.height)
        guard maxPixel > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// LRU：只保留最近用到的若干张，超出的立即释放位图
    private func touchCache(_ key: String) {
        imageCacheOrder.removeAll { $0 == key }
        imageCacheOrder.append(key)
        while imageCacheOrder.count > imageCacheLimit {
            let evict = imageCacheOrder.removeFirst()
            imageCache[evict] = nil
        }
    }

    /// 释放所有缓存的位图（停止壁纸 / 应用退出时调用）
    func purgeCaches() {
        imageCache.removeAll()
        imageCacheOrder.removeAll()
        assetCache.removeAll()
        releaseFreeMemory()
    }

    /// 把释放后仍被 malloc 扣住的空闲页归还系统
    private func releaseFreeMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    private var assetCache: [String: AVURLAsset] = [:]

    private func loadVideoSize(_ url: URL, completion: @escaping (CGSize) -> Void) {
        let key = url.path
        let asset = assetCache[key] ?? AVURLAsset(url: url)
        assetCache[key] = asset
        Task {
            var result = CGSize.zero
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let t = natural.applying(transform)
                result = CGSize(width: abs(t.width), height: abs(t.height))
            }
            let size = result
            await MainActor.run { completion(size) }
        }
    }
}

// MARK: - 控制面板

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var window: NSWindow!
    private var screens: [NSScreen] = []
    private var targetDisplayID: String = ""   // "" = 全部显示器

    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let libraryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let assignButton = NSButton(title: L10n.t("win.setWallpaper"), target: nil, action: nil)
    private let removeButton = NSButton(title: L10n.t("win.removeFromLibrary"), target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let zoomSlider = NSSlider(value: 1.0, minValue: 0.3, maxValue: 3.0, target: nil, action: nil)
    private let zoomValue = NSTextField(string: "100.00%")
    private let offXSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let offXValue = NSTextField(string: "0.00")
    private let offYSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let offYValue = NSTextField(string: "0.00")
    private let muteCheck = NSButton(checkboxWithTitle: L10n.t("win.muteVideo"), target: nil, action: nil)
    private let pauseButton = NSButton(title: L10n.t("win.pause"), target: nil, action: nil)
    private let autoStartCheck = NSButton(checkboxWithTitle: L10n.t("win.launchAtLogin"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var appMenuAutoItem: NSMenuItem?
    private var statusAutoItem: NSMenuItem?
    private var fullscreenMenuItem: NSMenuItem?
    private var batteryMenuItem: NSMenuItem?
    private var displaySubmenu: NSMenu?
    private var scaleModeSubmenu: NSMenu?
    // 软件主菜单里的对应子菜单（与菜单栏镜像）
    private var displaySubmenuApp: NSMenu?
    private var scaleModeSubmenuApp: NSMenu?
    private var settingsSubmenuApp: NSMenu?
    private var appPauseItem: NSMenuItem?
    private var settingsInfoItem: NSMenuItem?
    private var settingsSubmenuStatus: NSMenu?
    private let fullscreenLabel = NSTextField(labelWithString: "")
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?

    // 兼容性检测（HEV1 封装等 macOS 解不了的视频）
    private let warningLabel = NSTextField(labelWithString: "")
    private let fixButton = NSButton(title: L10n.t("compat.fixButton"), target: nil, action: nil)
    private var warningRow: NSStackView?
    private var incompatiblePath: String?

    // 自启走 LaunchAgent：无需授权弹窗，也不受 App Store 签名限制
    private let launchAgentLabel = "app.walllocus.autostart"
    private var launchAgentPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }
    private let scopeLabel = NSTextField(labelWithString: "")

    private var state: AppState { StateStore.shared.state }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：已有实例在跑时直接退出，避免壁纸窗口互相打架
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != myPID }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
        buildMenu()
        reloadScreens()
        buildWindow()
        buildStatusItem()
        startFullscreenMonitor()
        reloadScreens()
        reloadLibrary()
        WallpaperManager.shared.applyAll()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadScreens()
            WallpaperManager.shared.applyAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: 界面搭建

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = L10n.t("win.title")
        w.center()
        w.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "WallLocus")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        root.addArrangedSubview(title)
        let sub = NSTextField(labelWithString: L10n.t("win.subtitle"))
        sub.textColor = .secondaryLabelColor
        root.addArrangedSubview(sub)

        root.addArrangedSubview(separator())

        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        root.addArrangedSubview(row(L10n.t("win.targetDisplay"), targetPopup, width: 340))

        libraryPopup.target = self
        libraryPopup.action = #selector(librarySelectionChanged)
        root.addArrangedSubview(row(L10n.t("win.library"), libraryPopup, width: 340))

        let addBtn = NSButton(title: L10n.t("win.addFiles"), target: self, action: #selector(addFiles))
        addBtn.bezelStyle = .rounded
        assignButton.target = self
        assignButton.action = #selector(assignToTarget)
        assignButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeFromLibrary)
        removeButton.bezelStyle = .rounded
        let stopBtn = NSButton(title: L10n.t("win.stopAll"), target: self, action: #selector(stopAll))
        stopBtn.bezelStyle = .rounded
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        let row1 = NSStackView(views: [addBtn, assignButton, removeButton, stopBtn, pauseButton])
        row1.orientation = .horizontal
        row1.spacing = 8
        root.addArrangedSubview(row1)

        root.addArrangedSubview(separator())

        scopeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        scopeLabel.textColor = .labelColor
        root.addArrangedSubview(scopeLabel)

        for (i, m) in ScaleMode.allCases.enumerated() {
            modePopup.addItem(withTitle: m.label)
            if i == 0 { modePopup.selectItem(at: 0) }
        }
        modePopup.target = self
        modePopup.action = #selector(adjustmentChanged)
        root.addArrangedSubview(row(L10n.t("win.scaleMode"), modePopup, width: 300))

        zoomSlider.target = self
        zoomSlider.action = #selector(adjustmentChanged)
        zoomValue.alignment = .right
        root.addArrangedSubview(sliderRow(L10n.t("win.zoom"), zoomSlider, zoomValue))

        offXSlider.target = self
        offXSlider.action = #selector(adjustmentChanged)
        offXValue.alignment = .right
        root.addArrangedSubview(sliderRow(L10n.t("win.offsetX"), offXSlider, offXValue))

        offYSlider.target = self
        offYSlider.action = #selector(adjustmentChanged)
        offYValue.alignment = .right
        root.addArrangedSubview(sliderRow(L10n.t("win.offsetY"), offYSlider, offYValue))

        muteCheck.target = self
        muteCheck.action = #selector(adjustmentChanged)
        muteCheck.state = .on
        root.addArrangedSubview(muteCheck)

        autoStartCheck.target = self
        autoStartCheck.action = #selector(toggleAutoStart)
        autoStartCheck.state = isAutoStartEnabled() ? .on : .off
        root.addArrangedSubview(autoStartCheck)

        let hint = NSTextField(wrappingLabelWithString: L10n.t("win.hint"))
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 555
        root.addArrangedSubview(hint)

        // 兼容性警告行（默认隐藏，检测到无法解码的视频时显示）
        warningLabel.textColor = .systemRed
        warningLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        warningLabel.lineBreakMode = .byTruncatingTail
        fixButton.bezelStyle = .rounded
        fixButton.controlSize = .small
        fixButton.target = self
        fixButton.action = #selector(fixIncompatibleVideo)
        let wRow = NSStackView(views: [warningLabel, fixButton])
        wRow.orientation = .horizontal
        wRow.spacing = 8
        wRow.isHidden = true
        warningRow = wRow
        root.addArrangedSubview(wRow)

        root.addArrangedSubview(separator())
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)
        fullscreenLabel.textColor = .systemOrange
        fullscreenLabel.font = NSFont.systemFont(ofSize: 11)
        root.addArrangedSubview(fullscreenLabel)

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        w.contentView = container
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 555).isActive = true
        return b
    }

    private func row(_ label: String, _ control: NSView, width: CGFloat) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 90).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        let s = NSStackView(views: [l, control])
        s.orientation = .horizontal
        s.spacing = 10
        return s
    }

    private func sliderRow(_ label: String, _ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 90).isActive = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 320).isActive = true
        // 数值框：可编辑，回车或失焦时提交
        value.isEditable = true
        value.isSelectable = true
        value.isBordered = true
        value.bezelStyle = .roundedBezel
        value.alignment = .right
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.target = self
        value.action = #selector(numberFieldCommitted(_:))
        value.delegate = self
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let s = NSStackView(views: [l, slider, value])
        s.orientation = .horizontal
        s.spacing = 10
        return s
    }

    // MARK: 状态刷新

    private func reloadScreens() {
        screens = NSScreen.screens
        targetPopup.removeAllItems()
        targetPopup.addItem(withTitle: L10n.t("common.allDisplays"))
        for s in screens { targetPopup.addItem(withTitle: screenTitle(s)) }
        if !targetDisplayID.isEmpty, !screens.contains(where: { screenID($0) == targetDisplayID }) {
            targetDisplayID = ""
        }
        if targetDisplayID.isEmpty {
            targetPopup.selectItem(at: 0)
        } else if let idx = screens.firstIndex(where: { screenID($0) == targetDisplayID }) {
            targetPopup.selectItem(at: idx + 1)
        }
        refreshControls()
    }

    private func reloadLibrary() {
        libraryPopup.removeAllItems()
        if state.library.isEmpty {
            libraryPopup.addItem(withTitle: L10n.t("win.libraryEmpty"))
            libraryPopup.isEnabled = false
        } else {
            libraryPopup.isEnabled = true
            for item in state.library {
                libraryPopup.addItem(withTitle: "\(item.kind.label) · \(item.name)")
            }
            // 启动 / 刷新后恢复上次选中的素材
            if let last = state.lastSelectedItem,
               let idx = state.library.firstIndex(where: { $0.path == last }) {
                libraryPopup.selectItem(at: idx)
            }
        }
        refreshControls()
    }

    private var targetScreens: [NSScreen] {
        targetDisplayID.isEmpty ? screens : screens.filter { screenID($0) == targetDisplayID }
    }

    private var selectedItem: LibraryItem? {
        let idx = libraryPopup.indexOfSelectedItem
        guard idx >= 0, idx < state.library.count else { return nil }
        return state.library[idx]
    }

    private func refreshControls() {
        guard let item = selectedItem else {
            scopeLabel.stringValue = L10n.t("win.scope.none")
            adjustControlsEnabled(false)
            updateStatus()
            return
        }
        adjustControlsEnabled(true)
        let scopeName = targetDisplayID.isEmpty
            ? L10n.t("common.allDisplaysCount", screens.count)
            : (screens.first { screenID($0) == targetDisplayID }.map { screenTitle($0) } ?? L10n.t("common.unknownDisplay"))
        scopeLabel.stringValue = L10n.t("win.scope", scopeName, item.name)

        // 展示「第一块目标屏 × 该项目」已存下来的调整量
        guard let anyScreen = targetScreens.first ?? NSScreen.screens.first else {
            // 极端情况：系统尚未报告任何显示器
            scopeLabel.stringValue = L10n.t("win.scope.noDisplay")
            adjustControlsEnabled(false)
            updateStatus()
            return
        }
        let refDisplay = screenID(anyScreen)
        let adj = state.adjustment(display: refDisplay, item: item.path)
        modePopup.selectItem(at: ScaleMode.allCases.firstIndex(of: adj.mode) ?? 0)
        zoomSlider.doubleValue = adj.zoom
        offXSlider.doubleValue = adj.offsetX
        offYSlider.doubleValue = adj.offsetY
        muteCheck.state = state.muted ? .on : .off
        applyButtEnabled(item)
        updateValueLabels()
        updateStatus()
        checkCompatibility(item)
    }

    private func applyButtEnabled(_ item: LibraryItem) {
        assignButton.isEnabled = true
        removeButton.isEnabled = true
        muteCheck.isEnabled = (item.kind == .video)
    }

    private func adjustControlsEnabled(_ on: Bool) {
        modePopup.isEnabled = on
        zoomSlider.isEnabled = on
        offXSlider.isEnabled = on
        offYSlider.isEnabled = on
        zoomValue.isEnabled = on
        offXValue.isEnabled = on
        offYValue.isEnabled = on
        muteCheck.isEnabled = on
        assignButton.isEnabled = on
        removeButton.isEnabled = on
    }

    private func updateValueLabels() {
        zoomValue.stringValue = String(format: "%.2f%%", zoomSlider.doubleValue * 100)
        offXValue.stringValue = String(format: "%.2f", normalizeZero(offXSlider.doubleValue))
        offYValue.stringValue = String(format: "%.2f", normalizeZero(offYSlider.doubleValue))
    }

    /// 避免显示成 "-0.00"
    private func normalizeZero(_ v: Double) -> Double { abs(v) < 0.005 ? 0.0 : v }

    // MARK: 兼容性检测

    /// 检查视频能否被 macOS 解码；HEV1 封装的可一键修复
    private func checkCompatibility(_ item: LibraryItem) {
        guard item.kind == .video else {
            incompatiblePath = nil
            warningRow?.isHidden = true
            return
        }
        let path = item.path
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        Task {
            var ok = false
            var tag = ""
            do {
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let playable = (try? await track.load(.isPlayable)) ?? false
                    let decodable = (try? await track.load(.isDecodable)) ?? false
                    ok = playable && decodable
                    if let d = (try? await track.load(.formatDescriptions))?.first {
                        let sub = CMFormatDescriptionGetMediaSubType(d)
                        tag = [24, 16, 8, 0].map { String(UnicodeScalar(UInt8((sub >> UInt32($0)) & 0xFF))) }.joined()
                    }
                }
            } catch {
                ok = false
            }
            let finalOK = ok
            let finalTag = tag
            await MainActor.run { self.showCompatibility(finalOK, tag: finalTag, path: path) }
        }
    }

    private func showCompatibility(_ ok: Bool, tag: String, path: String) {
        guard selectedItem?.path == path else { return }   // 已切换素材，丢弃过期结果
        if ok {
            incompatiblePath = nil
            warningRow?.isHidden = true
            return
        }
        incompatiblePath = path
        if tag.lowercased() == "hev1" {
            warningLabel.stringValue = L10n.t("compat.hev1")
            fixButton.isHidden = false
        } else {
            warningLabel.stringValue = L10n.t("compat.undecodable", tag.isEmpty ? L10n.t("compat.unknown") : tag)
            fixButton.isHidden = true
        }
        warningRow?.isHidden = false
    }

    /// 就地改写封装标签：HEV1 → HVC1（等长替换，不重新编码，画质无损）
    @objc private func fixIncompatibleVideo() {
        guard let path = incompatiblePath else { return }
        let url = URL(fileURLWithPath: path)
        guard var bytes = try? Data(contentsOf: url) else {
            warningLabel.stringValue = L10n.t("compat.readFail")
            return
        }
        let pattern = Data([0x68, 0x65, 0x76, 0x31])   // "hev1"
        let replace = Data([0x68, 0x76, 0x63, 0x31])   // "hvc1"
        var hits = 0
        var start = bytes.startIndex
        while let r = bytes.range(of: pattern, in: start..<bytes.endIndex) {
            bytes.replaceSubrange(r, with: replace)
            hits += 1
            start = r.lowerBound + 4
        }
        guard hits > 0 else {
            warningLabel.stringValue = L10n.t("compat.noTag")
            return
        }
        // 先备份再写回
        let backup = url.deletingPathExtension().appendingPathExtension("hev1bak.mp4")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
        do {
            try bytes.write(to: url)
        } catch {
            warningLabel.stringValue = L10n.t("compat.writeFail", error.localizedDescription)
            return
        }
        warningLabel.stringValue = L10n.t("compat.fixed", hits, backup.lastPathComponent)
        fixButton.isHidden = true
        incompatiblePath = nil
        WallpaperManager.shared.applyAll()
        // 3 秒后复检：若文件仍有问题会重新亮出警告，否则保持成功提示后自动收起
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, let item = self.selectedItem else { return }
            self.checkCompatibility(item)
        }
    }

    private func updateStatus() {
        let playing = screens.filter { state.assignment[screenID($0)] != nil }.count
        let auto = isAutoStartEnabled() ? L10n.t("win.autoOn") : L10n.t("win.autoOff")
        statusLabel.stringValue = L10n.t("win.status", screens.count, playing, state.library.count, auto)
    }

    // MARK: 动作

    @objc private func targetChanged() {
        let idx = targetPopup.indexOfSelectedItem
        if idx > 0, idx - 1 < screens.count {
            targetDisplayID = screenID(screens[idx - 1])
        } else {
            targetDisplayID = ""
        }
        refreshControls()
    }

    @objc private func librarySelectionChanged() {
        if let item = selectedItem {
            StateStore.shared.update { $0.lastSelectedItem = item.path }
        }
        refreshControls()
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = L10n.t("win.openPanelTitle")
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie,
                                     .image, .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        StateStore.shared.update { st in
            for url in urls {
                let path = url.path
                if !st.library.contains(where: { $0.path == path }) {
                    st.library.append(LibraryItem(path: path, kind: MediaKind.detect(path)))
                }
            }
            // 目标屏尚未指定壁纸时，自动使用第一个新加入的素材
            let newPath = urls[0].path
            if targetDisplayID.isEmpty {
                for s in screens where st.assignment[screenID(s)] == nil {
                    st.assignment[screenID(s)] = newPath
                }
            } else if st.assignment[targetDisplayID] == nil {
                st.assignment[targetDisplayID] = newPath
            }
        }
        reloadLibrary()
        // 选中新加入的素材
        if let idx = state.library.firstIndex(where: { $0.path == urls[0].path }) {
            libraryPopup.selectItem(at: idx)
            StateStore.shared.update { $0.lastSelectedItem = urls[0].path }
        }
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    @objc private func assignToTarget() {
        guard let item = selectedItem else { return }
        StateStore.shared.update { st in
            for s in self.targetScreens {
                st.assignment[screenID(s)] = item.path
            }
        }
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    @objc private func removeFromLibrary() {
        guard let item = selectedItem else { return }
        StateStore.shared.update { st in
            st.library.removeAll { $0.path == item.path }
            for (display, path) in st.assignment where path == item.path {
                st.assignment[display] = nil
            }
            for display in st.adjustments.keys {
                st.adjustments[display]?.removeValue(forKey: item.path)
            }
        }
        reloadLibrary()
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    @objc private func stopAll() {
        StateStore.shared.update { st in
            st.assignment.removeAll()
        }
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    @objc private func adjustmentChanged() {
        updateValueLabels()
        guard let item = selectedItem else { return }
        let mode = ScaleMode.allCases[max(0, min(modePopup.indexOfSelectedItem, ScaleMode.allCases.count - 1))]
        let adj = Adjustment(mode: mode,
                             zoom: zoomSlider.doubleValue,
                             offsetX: offXSlider.doubleValue,
                             offsetY: offYSlider.doubleValue)
        StateStore.shared.update { st in
            for s in self.targetScreens {
                st.setAdjustment(adj, display: screenID(s), item: item.path)
            }
            st.muted = (muteCheck.state == .on)
        }
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    // MARK: 开机自启

    private func isAutoStartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func toggleAutoStart() {
        setAutoStart(autoStartCheck.state == .on)
    }

    @objc private func toggleAutoStartMenu() {
        setAutoStart(!isAutoStartEnabled())
    }

    private func setAutoStart(_ on: Bool) {
        let path = launchAgentPath
        let fm = FileManager.default
        if on {
            // 正常情况下 executablePath 总有值；兜底回退到当前进程路径
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(exe)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? xml.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            // 只删文件，绝不调用 launchctl unload —— 本进程正是由该 LaunchAgent 拉起的，
            // unload 会把自己一起杀掉；而 plist 删掉后下次登录自然就不会启动了
            try? fm.removeItem(atPath: path)
        }
        refreshAutoStartUI()
    }

    private func refreshAutoStartUI() {
        let on = isAutoStartEnabled()
        autoStartCheck.state = on ? .on : .off
        appMenuAutoItem?.state = on ? .on : .off
        statusAutoItem?.state = on ? .on : .off
        updateStatus()
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        // —— 应用菜单（保留系统标准项）——
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: L10n.t("menu.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let auto = NSMenuItem(title: L10n.t("menu.launchAtLogin"),
                              action: #selector(toggleAutoStartMenu),
                              keyEquivalent: "")
        auto.target = self
        auto.state = isAutoStartEnabled() ? .on : .off
        appMenuAutoItem = auto
        appMenu.addItem(auto)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.hide"),
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.t("menu.quit"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // —— 播放 ——
        mainMenu.addItem(submenu(title: L10n.t("menu.playback"), items: { [weak self] sub in
            guard let self else { return }
            let pause = NSMenuItem(title: L10n.t("menu.pauseWallpaper"), action: #selector(self.togglePause), keyEquivalent: "")
            pause.target = self
            self.appPauseItem = pause
            sub.addItem(pause)

            let all = NSMenuItem(title: L10n.t("menu.allDisplays"), action: #selector(self.playOnAll), keyEquivalent: "")
            all.target = self
            sub.addItem(all)

            let stop = NSMenuItem(title: L10n.t("menu.stopAll"), action: #selector(self.stopAll), keyEquivalent: "")
            stop.target = self
            sub.addItem(stop)
        }))

        // —— 显示器 ——
        let dispItem = NSMenuItem(title: L10n.t("menu.displays"), action: nil, keyEquivalent: "")
        let dispSub = NSMenu()
        dispSub.delegate = self
        dispItem.submenu = dispSub
        displaySubmenuApp = dispSub
        mainMenu.addItem(dispItem)

        // —— 缩放模式 ——
        let modeItem = NSMenuItem(title: L10n.t("menu.scaleMode"), action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        modeSub.delegate = self
        modeItem.submenu = modeSub
        scaleModeSubmenuApp = modeSub
        mainMenu.addItem(modeItem)

        // —— 设置 ——
        let setItem = NSMenuItem(title: L10n.t("menu.settings"), action: nil, keyEquivalent: "")
        let setSub = NSMenu()
        setSub.delegate = self
        setItem.submenu = setSub
        settingsSubmenuApp = setSub
        mainMenu.addItem(setItem)

        NSApp.mainMenu = mainMenu
    }

    /// 构建「设置」子菜单（两处菜单共用）
    private func buildSettingsItems(into sub: NSMenu) {
        sub.removeAllItems()

        let fs = NSMenuItem(title: L10n.t("menu.pauseOnFullscreen"),
                            action: #selector(toggleFullscreenPause),
                            keyEquivalent: "")
        fs.target = self
        fs.state = FullscreenMonitor.shared.isEnabled ? .on : .off
        fullscreenMenuItem = fs
        sub.addItem(fs)

        let bat = NSMenuItem(title: L10n.t("menu.pauseOnBattery"),
                             action: #selector(togglePauseOnBattery),
                             keyEquivalent: "")
        bat.target = self
        bat.state = Settings.pauseOnBattery ? .on : .off
        batteryMenuItem = bat
        sub.addItem(bat)

        let auto = NSMenuItem(title: L10n.t("menu.launchAtLogin"),
                              action: #selector(toggleAutoStartMenu),
                              keyEquivalent: "")
        auto.target = self
        auto.state = isAutoStartEnabled() ? .on : .off
        statusAutoItem = auto
        sub.addItem(auto)

        // 只读摘要：直接在这里填好内容（不能留空等下处刷新，
        // 因为子菜单每次展开都会整体重建，旧 item 引用会失效）
        sub.addItem(.separator())

        let info = NSMenuItem(title: currentAdjustmentSummary(), action: nil, keyEquivalent: "")
        info.isEnabled = false
        settingsInfoItem = info
        sub.addItem(info)
    }

    // MARK: 菜单栏图标（关窗后常驻）

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "photo.on.rectangle",
                              accessibilityDescription: "WallLocus")
            img?.isTemplate = true
            button.image = img
            button.toolTip = L10n.t("menu.tooltip")
        }
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: L10n.t("menu.open"), action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        // —— 播放 ——
        menu.addItem(submenu(title: L10n.t("menu.playback"), items: { [weak self] sub in
            guard let self else { return }
            let pause = NSMenuItem(title: L10n.t("menu.pauseWallpaper"), action: #selector(self.togglePause), keyEquivalent: "")
            pause.target = self
            self.pauseMenuItem = pause
            sub.addItem(pause)

            let all = NSMenuItem(title: L10n.t("menu.allDisplays"), action: #selector(self.playOnAll), keyEquivalent: "")
            all.target = self
            sub.addItem(all)

            let stop = NSMenuItem(title: L10n.t("menu.stopAll"), action: #selector(self.stopAll), keyEquivalent: "")
            stop.target = self
            sub.addItem(stop)
        }))

        // —— 显示器（每次展开动态重建，避免启动时序问题）——
        let dispItem = NSMenuItem(title: L10n.t("menu.displays"), action: nil, keyEquivalent: "")
        let dispSub = NSMenu()
        dispSub.delegate = self
        dispItem.submenu = dispSub
        displaySubmenu = dispSub
        menu.addItem(dispItem)

        // —— 缩放模式（当前选中素材）——
        let modeItem = NSMenuItem(title: L10n.t("menu.scaleMode"), action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        modeSub.delegate = self
        modeItem.submenu = modeSub
        scaleModeSubmenu = modeSub
        menu.addItem(modeItem)

        // —— 设置：所有功能开关与数值 ——
        let setItem = NSMenuItem(title: L10n.t("menu.settings"), action: nil, keyEquivalent: "")
        let setSub = NSMenu()
        setSub.delegate = self
        setItem.submenu = setSub
        settingsSubmenuStatus = setSub
        menu.addItem(setItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("menu.quit"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// 生成一个带二级菜单的条目
    private func submenu(title: String, items build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        return item
    }

    // MARK: 菜单动作

    @objc private func playOnAll() {
        WallpaperManager.shared.setPaused(false)
        refreshPauseUI()
    }

    @objc private func focusDisplay(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < screens.count else { return }
        guard sender.tag < screens.count else { return }
        targetDisplayID = screenID(screens[sender.tag])
        targetPopup.selectItem(at: sender.tag + 1)
        refreshControls()
        refreshMenuStates()
    }

    @objc private func focusAllDisplays() {
        targetDisplayID = ""
        targetPopup.selectItem(at: 0)
        refreshControls()
        refreshMenuStates()
    }

    @objc private func setScaleMode(_ sender: NSMenuItem) {
        let all = ScaleMode.allCases
        guard sender.tag < all.count else { return }
        modePopup.selectItem(at: sender.tag)
        adjustmentChanged()
        refreshMenuStates()
    }

    @objc private func togglePauseOnBattery() {
        Settings.pauseOnBattery.toggle()
        batteryMenuItem?.state = Settings.pauseOnBattery ? .on : .off
        refreshMenuStates()
    }

    /// 重建「显示器」子菜单（屏幕数可能因热插拔变化）
    private func rebuildDisplayMenu(into sub: NSMenu) {
        sub.removeAllItems()
        for (i, s) in screens.enumerated() {
            let it = NSMenuItem(title: screenTitle(s),
                                action: #selector(focusDisplay(_:)),
                                keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = (targetDisplayID == screenID(s)) ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let all = NSMenuItem(title: L10n.t("common.allDisplays"),
                             action: #selector(focusAllDisplays), keyEquivalent: "")
        all.target = self
        all.state = targetDisplayID.isEmpty ? .on : .off
        sub.addItem(all)
    }

    /// 重建「缩放模式」子菜单（勾选跟随当前 屏×素材）
    private func rebuildScaleModeMenu(into sub: NSMenu) {
        sub.removeAllItems()
        var current: ScaleMode? = nil
        if let item = selectedItem, let first = targetScreens.first {
            current = state.adjustment(display: screenID(first), item: item.path).mode
        }
        for (i, m) in ScaleMode.allCases.enumerated() {
            let it = NSMenuItem(title: m.label,
                                action: #selector(setScaleMode(_:)),
                                keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = (m == current) ? .on : .off
            sub.addItem(it)
        }
        // 没有选中素材时置灰
        if selectedItem == nil {
            for it in sub.items { it.isEnabled = false }
        }
    }

    /// 每次展开菜单前把勾选状态同步成当前真实值
    private func refreshMenuStates() {
        let pausedTitle = WallpaperManager.shared.isPaused ? L10n.t("menu.resumeWallpaper") : L10n.t("menu.pauseWallpaper")
        pauseMenuItem?.title = pausedTitle
        appPauseItem?.title = pausedTitle
        fullscreenMenuItem?.state = FullscreenMonitor.shared.isEnabled ? .on : .off
        batteryMenuItem?.state = Settings.pauseOnBattery ? .on : .off
        appMenuAutoItem?.state = isAutoStartEnabled() ? .on : .off
        statusAutoItem?.state = isAutoStartEnabled() ? .on : .off
        settingsInfoItem?.title = currentAdjustmentSummary()
    }

    /// 设置菜单底部那行只读摘要
    private func currentAdjustmentSummary() -> String {
        guard let item = selectedItem, let first = targetScreens.first ?? NSScreen.screens.first else {
            return L10n.t("compat.noSelection")
        }
        let a = state.adjustment(display: screenID(first), item: item.path)
        return L10n.t("compat.summary", a.zoom * 100, a.offsetX, a.offsetY)
    }

    private func startFullscreenMonitor() {
        let monitor = FullscreenMonitor.shared
        monitor.onChange = { [weak self] covered in
            WallpaperManager.shared.updateFullscreen(covered)
            self?.refreshFullscreenUI(covered)
        }
        monitor.start()
        refreshFullscreenUI([])
    }

    private func refreshFullscreenUI(_ covered: Set<String>) {
        fullscreenMenuItem?.state = FullscreenMonitor.shared.isEnabled ? .on : .off
        guard !covered.isEmpty else {
            fullscreenLabel.stringValue = ""
            return
        }
        let names = screens.filter { covered.contains(screenID($0)) }
            .map { $0.localizedName }
            .joined(separator: L10n.isChinese ? "、" : ", ")
        fullscreenLabel.stringValue = L10n.t("fs.paused", names)
    }

    @objc private func toggleFullscreenPause() {
        let m = FullscreenMonitor.shared
        m.isEnabled.toggle()
        fullscreenMenuItem?.state = m.isEnabled ? .on : .off
        if !m.isEnabled {
            WallpaperManager.shared.updateFullscreen([])
            refreshFullscreenUI([])
        }
    }

    private func refreshStatusMenu() {
        statusAutoItem?.state = isAutoStartEnabled() ? .on : .off
        refreshPauseUI()
    }

    /// 暂停状态同时反映到界面按钮和菜单栏
    private func refreshPauseUI() {
        let title = WallpaperManager.shared.isPaused ? L10n.t("win.resume") : L10n.t("win.pause")
        pauseButton.title = title
        pauseMenuItem?.title = title
    }

    @objc private func showPanel() {
        // 从菜单栏唤出面板时，把 Dock 图标一并恢复
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 窗口生命周期

    func windowWillClose(_ notification: Notification) {
        // 关窗后从 Dock 栏消失，只留菜单栏图标常驻（最小化不算关闭）
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func togglePause() {
        WallpaperManager.shared.setPaused(!WallpaperManager.shared.isPaused)
        refreshPauseUI()
    }

    // MARK: 数值输入框

    @objc private func numberFieldCommitted(_ sender: NSTextField) {
        commitNumberField(sender)
    }

    private func commitNumberField(_ field: NSTextField) {
        let original = field.stringValue
        let raw = original
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(raw) else {
            updateValueLabels()
            return
        }
        if field === zoomValue {
            // 未写百分号且输入 0.3–3.0 时按倍率解释，否则按百分比
            var percent = v
            if !original.contains("%") && v <= 3.0 { percent = v * 100 }
            zoomSlider.doubleValue = min(300.0, max(30.0, percent)) / 100.0
        } else if field === offXValue {
            offXSlider.doubleValue = min(1.0, max(-1.0, v))
        } else if field === offYValue {
            offYSlider.doubleValue = min(1.0, max(-1.0, v))
        } else {
            return
        }
        updateValueLabels()
        adjustmentChanged()
    }
}

extension AppDelegate: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commitNumberField(field)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 菜单栏每次展开前刷新勾选状态
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === displaySubmenu || menu === displaySubmenuApp {
            rebuildDisplayMenu(into: menu)
        } else if menu === scaleModeSubmenu || menu === scaleModeSubmenuApp {
            rebuildScaleModeMenu(into: menu)
        } else if menu === settingsSubmenuStatus || menu === settingsSubmenuApp {
            buildSettingsItems(into: menu)
        } else {
            refreshMenuStates()
        }
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
