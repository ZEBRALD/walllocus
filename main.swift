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


/// 玻璃面板的描边：沿圆角画一圈渐变高光。
/// 上边偏亮、下边偏暗，模拟光线自上方入射时的边缘折射，
/// 这是 macOS liquid glass 面板能在深色底上「浮起来」的关键。
/// 带渐变淡出的模糊层。
///
/// 关键限制：NSVisualEffectView 的背景模糊由窗口服务器合成，
/// 它**不经过视图自己的 layer 绘制**，所以给 blur 层加 layer.mask 是无效的 ——
/// mask 只能裁掉视图自己画的内容（这里是空），裁不掉背后的模糊。
/// 这正是「怎么调都是透明矩形、看不到模糊」的真正原因。
///
/// 可靠做法：把 blur 放进一个普通容器，用容器的 layer.mask 裁整个子树。
/// 容器是真图层，mask 对子树生效，模糊才会跟着淡出。
final class GradientMaskBlurView: NSView {
    private let blur = NSVisualEffectView()
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        common()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        common()
    }

    private func common() {
        wantsLayer = true

        // 对照 MeloX（youshen2/MeloX）的实现：它的播放器条用的是 SwiftUI
        // .glassEffect(.regular) / .regularMaterial + 一圈很淡的白色描边，
        // 观感是「几乎不着色的柔化 + 边缘高光」，不发灰也不发白。
        //
        // AppKit 里 .regularMaterial 对应的就是 .popover 这一档：
        // 它只做柔化、不叠暗色底。之前发灰是因为给了 darkAqua 外观 ——
        // 深色外观下系统会按深色配色压暗，材质选哪个都灰。
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        // 不强制 appearance：MeloX 在深色下用的是 .regularMaterial 且不覆盖",
        // 配色方案，观感依然透亮 —— 说明关键在材质本身，不在外观。
        // 之前强制 aqua 会白过头，正是因为外观被改成了亮色系。
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 末尾是 alpha 0 的白而非 clear：clear 会被当成「黑 + 0 alpha」，
        // 插值途中拖出一层灰，底部边界看得到一条线。
        // 过渡拉长：从 55% 处开始缓慢衰减到 100%，而不是在最后 15% 里骤降。
        // 骤降会形成一条可见的「边界线」，缓降才是照片 App 那种自然淡出。
        // 用等距色标 + 近似线性的 alpha 递减。
        //
        // 之前的分布是「前 55% 几乎不变（1.0 → 0.88）、后 45% 骤降」——
        // 观感就是「一段固定透明度 + 一段突然渐变」，中间还有可见的折点。
        // 色标等距、alpha 每段降幅接近，才是连续过渡。
        // 先慢后快：顶部一大段保持接近实心（托住标题、压住缩略图），
        // 后段才开始明显衰减，最后一段收干。
        //
        // 等速线性看着「太淡」：整条浮栏都在半透明状态，
        // 标题和缩略图都没有一个安静的底。照片 App 的顶栏其实很实，
        // 只在底部一小段让内容透出来。
        gradient.colors = [
            NSColor.white.cgColor,                                   // 1.00
            NSColor.white.withAlphaComponent(0.96).cgColor,          // 0.96
            NSColor.white.withAlphaComponent(0.88).cgColor,          // 0.88
            NSColor.white.withAlphaComponent(0.70).cgColor,          // 0.70
            NSColor.white.withAlphaComponent(0.42).cgColor,          // 0.42
            NSColor.white.withAlphaComponent(0.15).cgColor,          // 0.15
            NSColor.white.withAlphaComponent(0.0).cgColor,           // 0.00
        ]
        // 前 45% 只降到 0.88（慢），45%~80% 降到 0.15（快），
        // 最后 20% 收干。这是「先慢后快」的形状。
        gradient.locations = [0.0, 0.15, 0.30, 0.45, 0.62, 0.80, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.0)
        // 诊断开关：设为 true 时不加 mask，用来验证「模糊本身是否生效」。
        // 如果去掉 mask 仍看不到模糊，那问题不在遮罩，而在采样模式。
        if !Self.disableMaskForDiagnosis {
            layer?.mask = gradient
        }
    }

    /// 临时诊断用：绕开遮罩，直接看纯模糊
    static var disableMaskForDiagnosis = false

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    var sharedGradient: CAGradientLayer { gradient }
}

/// 纯装饰层：铺满容器但不接收任何鼠标事件。
/// 用它替代裸 NSView 做 tint / 描边 / 背景，避免「盖住控件导致点不动」。
final class PassthroughLayerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GlassRimView: NSView {
    /// 与面板一致的圆角
    var cornerRadius: CGFloat = 16

    /// 环境色调（由外部注入，随壁纸/周围内容更新）。
    var ambientColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    /// 是否用固定的极淡白线（MeloX 的做法）。
    /// 开着时忽略 ambientColor —— 玻璃的染色应该由材质层做，
    /// 而不是让边框跟着壁纸变色，那样反而看不出材质的边界。
    var usesFixedWhiteStroke = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    /// 这只是装饰性描边，铺满整个面板。
    /// 不穿透的话它会吃掉面板上所有控件（按钮、复选框、滑块）的鼠标事件 ——
    /// 表现为「点了没反应」，且因为视觉上什么都没变，极难定位。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = 1

        let rimColor: NSColor
        if usesFixedWhiteStroke {
            // MeloX 的原始参数：0.65pt 线宽 + 42% 白。
            // 之前写成 1pt，比原生粗一半，视觉上明显更亮 ——
            // 1pt 在 Retina 上是 2 个物理像素，0.65pt 只有约 1.3 个，
            // 后者才是那种「刚好能看见但几乎不存在」的细线。
            path.lineWidth = 0.65
            rimColor = NSColor.white.withAlphaComponent(0.42)
        } else {
            path.lineWidth = 1
            rimColor = Self.highlight(from: ambientColor)
        }
        rimColor.setStroke()
        path.stroke()

        // 顶部白色渐变高光已移除。
        //
        // 那是早期照 Vorssaint 做的「玻璃上缘反光」，在实际界面里表现为
        // 面板顶部一条明显的白色渐变色带，与 MeloX/照片 App 那种克制的
        // 材质不符。原生质感的边界只需要那圈 1pt 描边，不需要额外的高光层。
    }

    /// 由环境色推导描边色：保留色相，只提亮。
    ///
    /// 关键：不要和环境色「混白」—— 那样任何颜色都会被推到接近白，
    /// 色差被压扁成一模一样的灰。正确做法是把 HSV 的明度拉高、
    /// 饱和度略降，色相完全保留，这样红色壁纸的边就是偏红的暖白。
    static func highlight(from c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.sRGB) else {
            return NSColor(white: 1.0, alpha: 0.22)
        }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &v, alpha: &a)

        // 明度拉到 0.62~0.95（保证边框够亮），饱和度保留 45%（保住色相倾向）
        let newV = min(0.95, max(0.62, 0.55 + v * 0.45))
        let newS = s * 0.45

        let out = NSColor(hue: h, saturation: newS, brightness: newV, alpha: 0.34)
        return out.usingColorSpace(.sRGB) ?? NSColor(white: 0.9, alpha: 0.34)
    }
}



/// 顶部渐变遮罩：上层底色实、下层透明，让模糊层自然淡出。
/// 栏间拖拽条：鼠标移到栏间的缝隙时变成左右箭头，拖动可改变栏宽。
final class ResizeHandle: NSView {
    enum Side { case leftPane, rightPane }
    var side: Side = .leftPane
    var onDrag: ((CGFloat) -> Void)?

    private var lastX: CGFloat = 0
    private var tracking: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        lastX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = NSEvent.mouseLocation.x
        let dx = x - lastX
        lastX = x
        onDrag?(dx)
    }
}
final class FadeOverlay: NSView {
    var topColor: NSColor = .black
    var midColor: NSColor?
    var bottomColor: NSColor = .clear

    override func draw(_ dirtyRect: NSRect) {
        // 三段渐变：顶部实 → 腰部半透 → 底部透明。
        // 单段线性渐变在深色底上看起来太生硬，加个中间色更接近系统观感。
        let grad: NSGradient?
        if let mid = midColor {
            grad = NSGradient(colors: [topColor, mid, bottomColor],
                              atLocations: [0.0, 0.55, 1.0],
                              colorSpace: .deviceRGB)
        } else {
            grad = NSGradient(starting: topColor, ending: bottomColor)
        }
        grad?.draw(in: bounds, angle: -90)
    }
}

/// 采样面板背后的环境色，供玻璃描边染色。
///
/// 做法：用 CGWindowListCreateImage 抓窗口背后那一块屏幕（不含本窗口），
/// 取平均色。频率很低（1.5 秒一次）且区域很小，开销可以忽略。
final class AmbientColorSampler {
    static let shared = AmbientColorSampler()

    private var timer: Timer?
    private(set) var color: NSColor = .white
    /// 多个订阅者（左栏、右栏各一份）。原先只有一个闭包槽，
    /// 右栏赋值会把左栏的覆盖掉，表现为「只有一栏被染色」。
    private var observers: [(NSColor) -> Void] = []
    func observe(_ handler: @escaping (NSColor) -> Void) {
        observers.append(handler)
        handler(color)
    }

    /// 采样点（屏幕坐标）：面板附近的几个位置取平均
    private var samplePoints: [CGPoint] = []

    /// 由外部提供「当前壁纸路径」，采样器据此取平均色
    var wallpaperPathProvider: (() -> String?)?

    func start(points: [CGPoint] = []) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    private func currentWallpaperPath() -> String? {
        if let p = wallpaperPathProvider?(), !p.isEmpty { return p }
        // 兜底：直接从持久化状态读，避免「闭包还没接上/state 还没加载」的时序问题
        guard let d = UserDefaults.standard.dictionary(forKey: "app.walllocus.state") as? [String: Any],
              let json = d["walllocus.state.v1"] as? Data,
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let assign = obj["assignment"] as? [String: String] else { return nil }
        return assign.values.first
    }

    private func sample() {
        // 从「当前正在显示的壁纸」取平均色。
        //
        // 比截屏可靠得多：截屏会被本窗口自身挡住（面板就盖在采样点上），
        // desktopImageURL 又未必指向真实的显示内容。
        // 我们自己就知道当前铺的是哪张图，直接读它即可。
        guard let path = currentWallpaperPath() else {
            return
        }
        let url = URL(fileURLWithPath: path)

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return
        }
        // 缩略图方式解码：又快又省内存
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return
        }

        let w = 24, h = 24
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) {
            r += Double(data[i * 4])
            g += Double(data[i * 4 + 1])
            b += Double(data[i * 4 + 2])
        }
        // 退回全图平均色。
        //
        // 试过两种更强的方案都失败：
        // - 放大饱和度 ×3.2 → 把壁纸的色偏一起放大，整窗泛绿
        // - 只取最饱和 15% 像素 → 边缘色被选中，左右栏发蓝
        // 平均色虽然淡，但它至少是「这张图整体偏什么色」的诚实表达。
        let n = Double(w * h)
        let c = NSColor(srgbRed: CGFloat(r / n / 255),
                        green: CGFloat(g / n / 255),
                        blue: CGFloat(b / n / 255),
                        alpha: 1)
        color = c
        for h in observers { h(c) }
    }
}

struct LibraryItem: Codable, Equatable {
    var path: String
    var kind: MediaKind
    /// 用户自定义名称。为空时回退到文件名。
    /// 文件名常常是 UUID（如 4DC7C38D-B69C-...JPG），对人没有辨识度，
    /// 所以允许起一个有意义的名字。
    var alias: String? = nil
    /// 所属分类 = 壁纸文件夹下的子文件夹名。
    /// 空串表示直接放在壁纸文件夹根目录。扫描时自动推断，不手工维护。
    var category: String = ""

    var name: String { (path as NSString).lastPathComponent }

    /// 界面上应显示的名字：有别名用别名，否则用文件名
    var displayName: String {
        if let a = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return a
        }
        return name
    }

    var hasAlias: Bool {
        if let a = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return true
        }
        return false
    }
}

/// 一套「哪块屏用哪张壁纸」的配置快照。
///
/// 除了 assignment，还存下相关的那部分 adjustments —— 否则加载预设后
/// 每块屏的缩放/位置会退回默认值，用户还得重新调一遍构图。
struct WallpaperPreset: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    /// 显示器 UUID -> 素材路径
    var assignment: [String: String] = [:]
    /// 显示器 UUID -> 素材路径 -> 调整量（只存预设里用到的）
    var adjustments: [String: [String: Adjustment]] = [:]
    var createdAt: Date = Date()

    /// 界面上显示的摘要，例如「3 块屏」
    var displayCount: Int { assignment.count }
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
    /// 「停止全部壁纸」前的分配快照，供还原使用。
    /// 持久化存下来，重启后也能还原 —— 误点一次要重配三块屏太痛苦。
    /// 任何其它改动分配的操作都会把它清掉（见 StateStore.clearUndoAssignmentIfNeeded），
    /// 避免还原出一份和当前状态对不上的旧数据。
    var stoppedAssignment: [String: String]? = nil
    /// 用户保存的壁纸配置预设，可一键加载
    var presets: [WallpaperPreset] = []

    /// 手写解码：新版本加字段时必须让旧数据仍能读出。
    ///
    /// Swift 自动合成的 Codable 只对 Optional 属性容忍缺失的 key，
    /// 像 presets 这样的非 Optional 数组一旦缺失就会直接抛 keyNotFound，
    /// 结果是升级后丢掉用户全部配置（实测如此）。所以逐字段 decodeIfPresent。
    enum CodingKeys: String, CodingKey {
        case library, assignment, adjustments, muted, lastSelectedItem
        case stoppedAssignment, presets
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        library = try c.decodeIfPresent([LibraryItem].self, forKey: .library) ?? []
        assignment = try c.decodeIfPresent([String: String].self, forKey: .assignment) ?? [:]
        adjustments = try c.decodeIfPresent([String: [String: Adjustment]].self,
                                            forKey: .adjustments) ?? [:]
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        lastSelectedItem = try c.decodeIfPresent(String.self, forKey: .lastSelectedItem)
        stoppedAssignment = try c.decodeIfPresent([String: String].self,
                                                  forKey: .stoppedAssignment)
        presets = try c.decodeIfPresent([WallpaperPreset].self, forKey: .presets) ?? []
    }

    /// 当前是否有可还原的「刚才被停掉的分配」
    var canRestoreStopped: Bool {
        guard let s = stoppedAssignment else { return false }
        return !s.isEmpty
    }

    func adjustment(display: String, item: String) -> Adjustment {
        adjustments[display]?[item] ?? Adjustment()
    }

    mutating func setAdjustment(_ adj: Adjustment, display: String, item: String) {
        var perItem = adjustments[display] ?? [:]
        perItem[item] = adj
        adjustments[display] = perItem
    }

    func item(for path: String) -> LibraryItem? { library.first { $0.path == path } }

    /// 某个素材当前被哪些显示器使用（返回显示器 UUID 列表）
    func displaysUsing(_ path: String) -> [String] {
        assignment.filter { $0.value == path }.map { $0.key }
    }

    func isInUse(_ path: String) -> Bool {
        assignment.values.contains(path)
    }
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

    /// 素材原始像素尺寸
    var mediaSize: CGSize = .zero { didSet { layoutMedia() } }
    var kind: MediaKind = .video { didSet { layoutMedia() } }
    /// 当前生效的调整量（由管理器按 屏×项目 查出后灌入）
    var adjustment = Adjustment() {
        didSet {
            layoutMedia()
            // 播放速度同样属于「屏 × 项目」的属性，跟着 adjustment 一起下发。
            // 只在该值真的变化时才碰播放器，避免每次刷新都打断播放。
            if oldValue.playbackRate != adjustment.playbackRate {
                applyPlaybackRate()
            }
        }
    }

    /// 把 adjustment.playbackRate 应用到当前播放器。
    ///
    /// 不能直接写 player.rate —— 设 rate 会同时改变「播放/暂停」状态：
    /// 暂停中的壁纸会被这次设置意外启动。正确做法是设 defaultRate，
    /// 再只在本来就播放着的时候把 rate 跟上去。
    func applyPlaybackRate() {
        // 播放器由管理器持有，这里从图层反查，避免视图再存一份引用
        guard let p = playerLayer.player else { return }
        let r = Float(max(0.25, min(2.0, adjustment.playbackRate)))
        p.defaultRate = r
        if p.timeControlStatus == .playing {
            p.rate = r
        }
    }

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

    /// 每页显示多少个素材。行列会按窗口比例自动排布，这个值只决定「一页放几个」。

    /// 壁纸文件存放目录。首次使用时默认 ~/Pictures/WallLocus，
    /// 用户也可以改成任意目录。新添加的素材会被复制到这里集中管理。
    /// 左栏宽度（拖拽调整后持久化）
    /// 左栏分组顺序（默认：显示器 > 壁纸库 > 预设）。
    /// 存成逗号分隔的键序列，读取时校验并补全缺失项。
    static var groupOrder: [String] {
        get {
            let raw = UserDefaults.standard.string(forKey: "sidebarGroupOrder") ?? ""
            let parts = raw.split(separator: ",").map(String.init)
                .filter { ["display", "library", "preset"].contains($0) }
            return parts.isEmpty ? ["display", "library", "preset"] : parts
        }
        set {
            UserDefaults.standard.set(newValue.joined(separator: ","), forKey: "sidebarGroupOrder")
        }
    }

    /// 图库排序键：name / date
    static var sortKey: String {
        get { UserDefaults.standard.string(forKey: "librarySortKey") ?? "name" }
        set { UserDefaults.standard.set(newValue, forKey: "librarySortKey") }
    }

    /// 排序方向：true = 升序
    static var sortAscending: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "librarySortAscending") == nil { return true }
            return d.bool(forKey: "librarySortAscending")
        }
        set { UserDefaults.standard.set(newValue, forKey: "librarySortAscending") }
    }

    /// 是否启用「拖拽壁纸到屏幕即应用」（默认开启）。
    /// 关闭后拖拽只用于把文件复制出去，屏幕上不再出现提示卡片。
    static var dragToApplyEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "dragToApplyEnabled") == nil { return true }
            return d.bool(forKey: "dragToApplyEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "dragToApplyEnabled") }
    }

    /// 网格里是否显示图片文件名（默认显示）
    static var showGridFileNames: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "showGridFileNames") == nil { return true }
            return d.bool(forKey: "showGridFileNames")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showGridFileNames") }
    }

    static var paneSidebarWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "paneSidebarWidth")
            return v > 0 ? v : 200
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "paneSidebarWidth") }
    }

    /// 右栏宽度
    /// 网格列数：3 / 5 / 7 / 9（照片 App 的档位）
    static var gridColumnCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "gridColumnCount")
            return v == 3 || v == 5 || v == 7 || v == 9 ? v : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: "gridColumnCount") }
    }

    /// 网格样式：false = 间距网格（保持原比例），true = 正方形填充
    static var gridSquareFill: Bool {
        get { UserDefaults.standard.bool(forKey: "gridSquareFill") }
        set { UserDefaults.standard.set(newValue, forKey: "gridSquareFill") }
    }

    /// 右栏是否折叠（持久化：用户收起后重启不该又展开）
    static var detailPaneCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "detailPaneCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "detailPaneCollapsed") }
    }

    static var paneDetailWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "paneDetailWidth")
            return v > 0 ? v : 300
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "paneDetailWidth") }
    }

    static var wallpaperFolder: URL {
        get {
            let d = UserDefaults.standard
            if let s = d.string(forKey: "wallpaperFolder"), !s.isEmpty {
                return URL(fileURLWithPath: s, isDirectory: true)
            }
            let base = FileManager.default.urls(for: .picturesDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Pictures")
            return base.appendingPathComponent("WallLocus", isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "wallpaperFolder")
        }
    }

    /// 用户是否已经确认过文件夹位置（首次启动时用来决定要不要弹引导）
    static var hasChosenWallpaperFolder: Bool {
        get { UserDefaults.standard.bool(forKey: "hasChosenWallpaperFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "hasChosenWallpaperFolder") }
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

    /// 当前被全屏应用遮挡的显示器（侧栏状态点用它判断「已暂停」）
    var coveredScreens: Set<String> { last }

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
        // 0.5s：全屏状态一变，侧栏圆点要能马上反映出来。
        // 这个轮询只做窗口枚举与矩形比较，开销可以忽略。
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check()
        }
        t.tolerance = 0.15             // 允许系统攒批触发，省电
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

    /// 系统内存吃紧时主动放掉位图缓存。
    /// 位图随时可以按需重新解码，但内存紧张时继续持有会影响整机表现。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            self?.purgeCaches()
        }
        src.resume()
        memoryPressureSource = src
    }

    final class Entry {
        let window: NSWindow
        let view: WallpaperView
        var player: AVPlayer?
        var path: String?
        /// 该屏当前引用的位图缓存键；用于在屏移除时精确回收
        var cacheKey: String?
        init(window: NSWindow, view: WallpaperView) {
            self.window = window
            self.view = view
        }
    }

    private var entries: [String: Entry] = [:]
    private var loopTokens: [String: NSObjectProtocol] = [:]
    /// 图片缓存：按「路径 + 目标像素尺寸」为键，避免不同屏共用一张大图
    /// 位图缓存。cap = 生成时使用的长边上限（maxPixel），
    /// 用于判断已有位图是否「至少和这次请求一样清晰」。
    private struct CachedBitmap {
        let image: CGImage
        let size: CGSize
        let cap: CGFloat
    }
    private var imageCache: [String: CachedBitmap] = [:]
    /// 位图缓存上限。
    ///
    /// 实测（2026-10-24）：每解码一张位图，其像素数据会被 Core Graphics
    /// 长期保留（不随我们的引用释放而回收，malloc_zone_pressure_relief 也无效），
    /// 单张约 24 MB，累计到约 770 MB 才收敛。因此「少解码」比「少持有」重要得多：
    /// 缓存越多，重复切换时越不会触发新解码，总占用反而更低且可控。
    /// 但每张是全屏位图（2160×2880 约 24MB），8 张就是 192MB ——
    /// 对「同时只显示 3 张」的实际用量来说过度了，取 4 张（LRU 淘汰）。
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

    /// 把某个素材的播放速度应用到正在显示它的那些屏。
    /// 不重建窗口：改速度不该让视频重新开始。
    func applyPlaybackRateTo(path: String) {
        let state = StateStore.shared.state
        for (id, entry) in entries where entry.path == path {
            let adj = state.adjustment(display: id, item: path)
            entry.view.adjustment = adj        // didSet 会顺手应用速度
        }
    }

    /// 只切换已有播放器的静音状态。
    ///
    /// 静音是全局开关，改它不该重建壁纸窗口：
    /// 重建会打断正在播放的视频（从头开始），而这个操作本身与画面无关。
    func setMuted(_ muted: Bool) {
        for (_, entry) in entries {
            entry.player?.isMuted = muted
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
        pruneCache()
    }

    private func apply(path: String, adj: Adjustment, muted: Bool, screen: NSScreen, id: String) {
        let entry = entries[id] ?? makeEntry(screen: screen)
        if entry.window.frame != screen.frame {
            entry.window.setFrame(screen.frame, display: true)
        }
        entry.view.adjustment = adj
        // 位图长边 = min(源图长边, 屏幕长边)
        //
        // 下界取屏幕长边：图层以 point 摆放，Retina 屏 1 point = scale 个物理像素，
        // 位图不够大时 Core Animation 会放大合成，边缘发虚。
        // 上界取源图长边：放大原图没有细节增益，只多占内存。
        //
        // 必须按「长边」比较，不能宽高各自钳制再取较大者——那会破坏宽高比。
        // 竖构图源图 2160x2880 放进横屏 2940x1912 时，各自钳制得到 2160x1912，
        // 长边取 2160，于是源图高度被压到 2160、宽度被压到 1620，反而比原图更糊。
        // 按长边比较则得到 min(2880, 2940) = 2880，完整保留源图分辨率。
        let scale = screen.backingScaleFactor
        let screenLong = max(screen.frame.width, screen.frame.height) * scale
        var maxPixel = max(256, screenLong)
        if let source = Self.sourcePixelSize(path: path) {
            maxPixel = min(maxPixel, max(source.width, source.height))
        }
        let kind = MediaKind.detect(path)

        if entry.path != path {
            teardownMedia(entry, id: id)
            entry.path = path
            entry.view.kind = kind
            if kind == .video {
                setupVideo(entry, path: path, muted: muted, id: id)
            } else {
                setupImage(entry, path: path, maxPixel: maxPixel)
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
        // 断开内容视图，让图层树尽早释放（显示器拔掉时能立刻回收显存/后备存储）
        e.window.contentView = nil
        entries[id] = nil
        pruneCache()
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
        entry.cacheKey = nil
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

    /// 查「这块屏 × 这个素材」的播放速度
    private func rateFor(path: String, id: String) -> Float {
        let adj = StateStore.shared.state.adjustment(display: id, item: path)
        return Float(max(0.25, min(2.0, adj.playbackRate)))
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
        // 每个「屏 × 素材」各有自己的速度，建播放器时就按它初始化
        player.defaultRate = rateFor(path: path, id: id)
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

    private func setupImage(_ entry: Entry, path: String, maxPixel: CGFloat) {
        // 键只含路径：同一张图在多块不同尺寸的屏上只保留一份位图。
        //
        // 不能用「实际宽高 >= 目标宽高」判断——downsample 约束的是长边（maxPixel），
        // 竖图放进横屏时生成结果的宽度会明显小于目标宽度，那样会误判成「不够清晰」
        // 而每次重新解码。改为比较生成时的长边上限 cap：只要已有位图的 cap
        // 不小于本次所需，清晰度就一定不差于重新生成的结果。
        let need = maxPixel
        if let cached = imageCache[path], cached.cap + 1 >= need {
            entry.view.showImage(cached.image, size: cached.size)
            entry.cacheKey = path
            touchCache(path)
            return
        }
        guard let cg = Self.downsample(path: path, maxPixel: maxPixel) else {
            entry.view.clearMedia()
            return
        }
        let size = CGSize(width: cg.width, height: cg.height)
        imageCache[path] = CachedBitmap(image: cg, size: size, cap: need)
        entry.cacheKey = path
        touchCache(path)
        entry.view.showImage(cg, size: size)
    }

    /// 把图片解码到长边不超过 maxPixel 的位图（用 ImageIO 直接出图，跳过 NSImage，
    /// 内存峰值只占降采样后的位图，不产生原图整幅位图）。
    /// 传 nil 之外的值时按长边等比缩放，宽高比由 ImageIO 保持。
    static func downsample(path: String, maxPixel: CGFloat) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        guard maxPixel > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 读取源图的原始像素尺寸（图片走 ImageIO）。
    /// 用于把位图目标尺寸钳制在「不超过原图」的范围内，避免无意义放大。
    static func sourcePixelSize(path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 1, h > 1 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// LRU：只保留最近用到的若干张，超出的立即释放位图
    private func touchCache(_ key: String) {
        imageCacheOrder.removeAll { $0 == key }
        imageCacheOrder.append(key)
        var evicted = false
        while imageCacheOrder.count > imageCacheLimit {
            let evict = imageCacheOrder.removeFirst()
            imageCache[evict] = nil
            evicted = true
        }
        if evicted { releaseFreeMemory() }
    }

    /// 释放所有缓存的位图（停止壁纸 / 应用退出时调用）
    /// 释放「当前没有任何屏幕在用」的位图。
    ///
    /// 实测（2026-10-24）：暂停/清理一次可把进程占用从 308 MB 降到 123 MB，
    /// 说明这些位图是能真正回收的——关键在于必须主动调用，而不是等 LRU 满员。
    /// 因此每次重排后都把已经不在屏幕上的位图放掉。
    private func pruneCache() {
        let live = Set(entries.values.compactMap { $0.cacheKey })
        guard imageCache.count > live.count else { return }
        for key in imageCache.keys where !live.contains(key) {
            imageCache[key] = nil
        }
        imageCacheOrder.removeAll { !live.contains($0) }
        releaseFreeMemory()
    }

    func purgeCaches() {
        imageCache.removeAll()
        imageCacheOrder.removeAll()
        assetCache.removeAll()
        // 缩略图也是可重建的派生数据，内存吃紧时一并让位。
        // 下次打开面板会按需重新生成（8 张图约 35ms，代价可接受）。
        ThumbnailStore.shared.clear()
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSearchFieldDelegate {

    var window: NSWindow!
    private var screens: [NSScreen] = []
    private var targetDisplayID: String = ""   // "" = 全部显示器

    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let libraryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thumbnailGrid = ThumbnailGrid(frame: .zero)
    /// 右栏视图（用于判断点击是否落在右栏 —— 右栏有「应用预设」操作，
    /// 点它不该清掉预设的选中）
    private weak var detailPaneView: NSView?
    /// 中栏容器（折叠右栏时搜索框要改绑它）
    private weak var libraryPaneView: NSView?
    /// 中栏顶部的渐变模糊浮栏（标题「文件夹名 + 数量」放这里）
    private weak var libraryHeaderBlur: NSVisualEffectView?
    /// 通栏渐变模糊层（横跨三栏，压在内容之上、顶栏控件之下）
    private weak var globalHeaderBlur: GradientMaskBlurView?
    /// 浮栏的渐变遮罩：上实下透，让网格内容从中穿过时自然隐去
    private weak var libraryHeaderMask: CAGradientLayer?
    /// 顶栏通栏的渐变模糊底（含右栏区域）
    private weak var topBarBlur: GradientMaskBlurView?
    private weak var topBarMask: CAGradientLayer?
    /// 浮栏里的标题与副标题
    private weak var libraryHeaderTitle: NSTextField?
    private weak var libraryHeaderSubtitle: NSTextField?
    /// 右栏左侧的拖拽条（折叠时隐藏）
    private weak var rightHandleView: NSView?
    /// 素材名称编辑框（选中后可改名，解决 UUID 文件名认不出的问题）
    private let nameField = NSTextField(string: "")
    /// 「恢复文件名」按钮：仅在当前素材有别名时可用
    private let resetNameButton = NSButton(title: "", target: nil, action: nil)
    /// 「停止全部壁纸」/「还原壁纸」—— 同一个按钮，按状态切换标题与行为
    private let stopButton = NSButton(title: "", target: nil, action: nil)
    /// 清除当前所选显示器上的壁纸（不动其它屏）
    private let clearCurrentButton = NSButton(title: "", target: nil, action: nil)
    /// 清除所有显示器上的壁纸（一次性、不可撤销；与 stopButton 的区别是它不做快照）
    private let clearAllButton = NSButton(title: "", target: nil, action: nil)

    // 三栏布局新增
    private let sidebar = SidebarNavigator(frame: .zero)
    private let searchField = NSSearchField(frame: .zero)
    /// 点击空白结束编辑的事件监听器
    private var clickMonitor: Any?
    /// 上次扫描时记录的文件夹指纹（用于判断磁盘是否真的变了）
    private var lastFolderFingerprint = ""
    /// 首次扫描是否已完成（避免 applicationDidBecomeActive 抢先扫）
    private var didFinishInitialScan = false
    /// 文件分辨率缓存（路径 → "宽x高"），避免重复异步解析导致文字闪烁
    private var resolutionCache: [String: String] = [:]
    private let settingsButton = CircleGlassButton()
    /// 折叠右栏按钮：浏览大量壁纸时把操作栏收起来，让中栏独享宽度
    private let collapseButton = CircleGlassButton()
    /// 返回上一级目录（仅在子文件夹内可见）
    private let backButton = CircleGlassButton()
    /// 网格列数减 / 加（步长 2，范围 3...9）
    private let colMinusButton = CircleGlassButton()
    private let colPlusButton = CircleGlassButton()
    /// 网格样式切换：间距网格 ↔ 正方形填充
    private let gridStyleButton = CircleGlassButton()
    /// 搜索折叠态的圆钮
    private let searchToggleButton = CircleGlassButton()
    /// 标题组（返回按钮 + 标题两行），整体绑定到左栏右缘
    private weak var titleRowStack: NSStackView?
    /// 搜索框展开态的宽度约束（响应式变形时调整）
    private var searchWidthConstraint: NSLayoutConstraint?
    /// 工具区 stack（列数、样式、搜索、加号、齿轮、折叠）
    private weak var toolsStack: NSStackView?
    /// 搜索框是否处于展开态（窄窗口下收成圆钮）
    private var searchExpanded = false
    /// 右栏是否处于折叠状态
    private var detailCollapsed = Settings.detailPaneCollapsed
    private let addButton = NSButton(title: "", target: nil, action: nil)
    /// 顶栏的「添加壁纸」按钮（加号）
    private let addFilesButton = CircleGlassButton()
    private let paneTitle = NSTextField(labelWithString: "")
    /// 顶栏渐变模糊的遮罩（需要在 resize 时同步 frame）
    private var topFadeLayer: CAGradientLayer?
    /// 左栏宽度约束（可拖拽调整）
    private var sidebarWidthConstraint: NSLayoutConstraint!
    /// 顶栏标题左边距约束（绑定左栏右缘）
    private var titleLeadingConstraint: NSLayoutConstraint?
    /// 搜索框宽度约束（跟随右栏）
    /// 搜索框左缘约束（绑定右栏左缘）
    private var searchFieldLeftConstraint: NSLayoutConstraint?
    /// 搜索框占位约束（重绑后必须取消，否则两条 leading 冲突）
    private var searchPlaceholderConstraint: NSLayoutConstraint!
    /// 右栏容器（供搜索框绑定左缘）
    private weak var detailPane: NSView?
    /// 顶栏标题与顶栏容器（供重启时重绑）
    private weak var topTitleView: NSTextField?
    private weak var topBarHost: NSView?
    /// 右栏宽度约束
    private var rightWidthConstraint: NSLayoutConstraint!
    /// 右栏右缘约束：折叠时把它推出窗口，中栏才能真正变宽
    private var rightTrailingConstraint: NSLayoutConstraint!
    /// 中栏右缘：展开时贴右栏，折叠时贴窗口右缘
    private var middleTrailingConstraint: NSLayoutConstraint!
    /// 折叠态下使用的备用约束（贴 container 右缘）
    private var middleTrailingCollapsed: NSLayoutConstraint?
    /// 中栏宽度约束（随左右栏变化重算）
    /// 右栏元素宽度约束（随栏宽更新）
    private var detailWidthConstraints: [NSLayoutConstraint] = []
    /// 搜索去抖计时器（避免每按键重建网格）
    private var searchDebounce: Timer?
    /// 分类列表缓存（扫描文件夹时清空）
    private var cachedCategories: [String]?
    /// 当前栏宽（拖拽时改这两个值）
    private var sidebarWidth: CGFloat = Settings.paneSidebarWidth
    private var rightWidth: CGFloat = Settings.paneDetailWidth
    private var baseGlass: NSVisualEffectView?
    private var baseTint: NSView?
    private var topTitle: NSTextField?
    private var topSubtitle: NSTextField?
    private var topFadeHost: NSView?
    private let paneSubtitle = NSTextField(labelWithString: "")
    /// 壁纸文件详情（只读）：分辨率 / 大小 / 分类 / 位置
    private let fileInfoLabel = NSTextField(labelWithString: "")
    private var libraryEmptyLabel: NSView?
    /// 空状态卡片里的标题与说明，按场景（空库 / 搜索无结果 / 分类为空）切换文案
    private weak var emptyTitleLabel: NSTextField?
    private weak var emptyStepsLabel: NSTextField?
    private weak var emptyActionButton: NSButton?
    /// 右栏顶部的当前素材大图预览
    private let previewPane = PreviewPane(frame: .zero)
    private var detailScroll: NSScrollView?
    private var detailDoc: NSView?
    private var detailRoot: NSStackView?
    /// 侧栏当前选中项；nil 表示还没选
    /// 侧栏选中项。初始停在「壁纸库 · 全部」——
    /// 这是用户打开面板后最常看的地方，也让侧栏一启动就有明确高亮。
    // 左栏三组各自独立的选中项（组内单选，组间互不影响）
    private var displaySelection: SidebarSelection = .allDisplays
    private var librarySelection: SidebarSelection = .library(nil)
    private var presetSelection: SidebarSelection?
    /// 搜索过滤词（空 = 不过滤）
    private var searchQuery: String = ""
    /// 当前壁纸库筛选（nil = 全部）
    private var libraryFilter: String? = nil
    /// 当前网格列数（随窗口宽度变化）
    private var gridColumns: Int = 5
    /// 当前网格行数（随窗口高度变化）
    private var gridRows: Int = 3
    /// 预设：下拉选择 + 保存/加载/删除
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let savePresetButton = NSButton(title: "", target: nil, action: nil)
    private let loadPresetButton = NSButton(title: "", target: nil, action: nil)
    private let deletePresetButton = NSButton(title: "", target: nil, action: nil)
    private var nameFieldRow: NSStackView?
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
    /// 播放速度分段控件（仅视频可见）
    private let rateControl = NSSegmentedControl(labels: ["0.5×", "1×", "1.5×", "2×"],
                                                 trackingMode: .selectOne,
                                                 target: nil, action: nil)
    /// 速度整行（含标题），图片时整体隐藏
    private var rateRow: NSStackView?
    /// 自定义速度输入框：预设档位之外的任意值
    private let rateField = NSTextField(string: "1.0")
    /// 构图摘要：用自然语言说明「这张图在这块屏」的构图状态。
    /// 这是产品唯一的差异化能力，但此前只以三个滑块 + 三个数字呈现，
    /// 用户根本不知道这些值是按「屏 × 图」记住的。
    private let framingSummary = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: L10n.t("win.pause"), target: nil, action: nil)
    private let autoStartCheck = NSButton(checkboxWithTitle: L10n.t("win.launchAtLogin"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    /// 导入进行中的浮层（右下角，压在状态栏上方）
    private var importBanner: NSView?
    private var importLabel: NSTextField?
    private var importIndicator: NSProgressIndicator?
    /// 导入完成后的绿色对勾（与转圈同位置互斥显示）
    private var importCheck: NSImageView?
    /// 正在进行的导入批次计数。用计数而非布尔，才能正确处理并发导入。
    private var importInFlight = 0
    /// 结果浮标的显示序号，用于让旧的延时关闭失效
    private var toastCount = 0
    private var appMenuAutoItem: NSMenuItem?
    private var statusAutoItem: NSMenuItem?
    private var fullscreenMenuItem: NSMenuItem?
    private var batteryMenuItem: NSMenuItem?
    private var scaleModeSubmenu: NSMenu?
    // 软件主菜单里的对应子菜单（与菜单栏镜像）
    private var scaleModeSubmenuApp: NSMenu?
    private var settingsSubmenuApp: NSMenu?
    private var appSubmenuApp: NSMenu?
    private var playbackMenuApp: NSMenu?
    private var playbackMenuStatus: NSMenu?
    private var wallpaperMenuApp: NSMenu?
    private var displaysMenuApp: NSMenu?
    private var libraryMenuApp: NSMenu?
    private var presetsMenuApp: NSMenu?
    private var appPauseItem: NSMenuItem?
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

    /// App 重新回到前台时检查磁盘：用户多半刚在访达里动过文件。
    func applicationDidBecomeActive(_ notification: Notification) {
        // 首次启动由 didFinishLaunching 负责，这里避免重复扫
        guard didFinishInitialScan else { return }
        refreshLibraryIfNeeded()
    }

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
        ThumbnailItem.fillsSquare = Settings.gridSquareFill
        buildWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        }
        // 恢复上次的右栏折叠状态（必须在 buildWindow 之后，
        // 那时 rightWidthConstraint 才存在）
        if detailCollapsed {
            applyDetailCollapse(animated: false)
        }
        buildStatusItem()
        startFullscreenMonitor()
        reloadScreens()
        // 首次使用时确认壁纸文件夹位置。
        // 放在窗口建好之后：这样弹窗有父窗口可依附，不会飘在桌面中央。
        ensureWallpaperFolder()
        scanWallpaperFolder()
        // 记下这次扫描后的指纹与完成标记：
        // 之后的 applicationDidBecomeActive / 切分类等只做增量判断，不重复全量扫。
        lastFolderFingerprint = folderFingerprint()
        didFinishInitialScan = true
        // 应用「网格显示文件名」设置
        ThumbnailItem.showsFileNames = Settings.showGridFileNames
        reloadLibrary()
        reloadPresets()

        WallpaperManager.shared.applyAll()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadScreens()
            WallpaperManager.shared.applyAll()
            // 屏参变了，壁纸可能也换屏了 —— 触发一次重采
            AmbientColorSampler.shared.start(points: [])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: 界面搭建

    /// 三栏布局：左导航 / 中图库 / 右详情，顶栏与底栏贯穿。
    ///
    /// 为什么放弃单列堆叠：原来 20 多个控件挤在 555px 宽的一列里，
    /// 「选屏」「浏览素材」「调参数」三种操作互相干扰，滑块也几乎没有空间。
    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        // 标题栏不放文字：应用内已有「WallLocus」品牌区，系统标题会与之重叠。
        // 保留标题栏本身（用户要靠它拖动窗口），只是把文字藏起来。
        w.title = ""
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 900, height: 600)
        w.center()
        w.isReleasedWhenClosed = false

        // 窗口自身不透明，并由它提供基础底色。
        // 侧栏毛玻璃用 .withinWindow 采样这层底色 —— 桌面不会透进来。
        // （早先为了「透出桌面」设成 isOpaque=false + clear，现在设计改了：
        //   要求毛玻璃只透软件自己的 UI 底色。）
        w.titlebarAppearsTransparent = true
        // 窗口透明：这是 liquid glass 能「随壁纸变色」的前提。
        // 每一层都铺玻璃，所以不会露出桌面 —— 见 container 的底玻璃。
        w.isOpaque = false
        w.backgroundColor = .clear
        // 内容延伸到标题栏下方，否则顶部会留一条与内容割裂的横带
        w.styleMask.insert(.fullSizeContentView)
        // 固定深色外观：毛玻璃在浅色外观下会发白，和壁纸缩略图深底不搭
        w.appearance = NSAppearance(named: .darkAqua)

        // 整个面板都是拖放目标
        let container = DropZoneView()
        // 底层也用 liquid glass：它是整个窗口的「底」，最实的一层。
        // 窗口透明后，这层玻璃负责模糊桌面壁纸，形成整窗的环境色基底。
        container.wantsLayer = true
        let baseBlur = NSVisualEffectView()
        baseBlur.material = .underWindowBackground
        baseBlur.blendingMode = .behindWindow
        baseBlur.state = .active
        baseBlur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(baseBlur, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            baseBlur.topAnchor.constraint(equalTo: container.topAnchor),
            baseBlur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            baseBlur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            baseBlur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // 底玻璃保持原样的模糊结果（不额外压暗）：
        // 上面再垫一层会把它压成接近纯色，上层玻璃采样什么都是灰的。
        // 明暗交给各层自己的 tint 控制。
        self.baseGlass = baseBlur
        container.onDrop = { [weak self] paths in
            self?.handleDrop(paths)
        }

        // ── 顶栏 ──────────────────────────────────────────────

        let topBar = buildTopBar()

        // ── 三栏 ──────────────────────────────────────────────
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelect = { [weak self] sel in self?.sidebarSelectionChanged(sel) }
        // 素材拖到左栏的显示器行 → 应用到那块屏
        sidebar.onDropWallpaper = { [weak self] path, displayID in
            self?.applyWallpaper(path: path, displayID: displayID)
        }
        // 右键分类行：显示文件夹位置 / 整类移到废纸篓
        sidebar.onCategoryMenu = { [weak self] cat, view in
            self?.makeCategoryMenu(category: cat, view: view)
        }
        // 素材拖到屏幕上的提示卡片 → 应用到那块屏
        DropCoordinator.shared.onApply = { [weak self] path, screen in
            self?.applyWallpaper(path: path, displayID: screenID(screen))
        }
        sidebar.onSavePreset = { [weak self] in self?.savePreset() }
        sidebar.onNewCategory = { [weak self] in self?.newCategory() }
        sidebar.onPresetMenu = { [weak self] id, view in
            self?.makePresetMenu(id: id, view: view)
        }

        let middle = buildLibraryPane()
        libraryPaneView = middle
        let right = buildDetailPane()
        detailPaneView = right

        // 竖分隔线
        // 竖分隔线：自绘 1pt 单线（NSBox.separator 当竖线用会画成双线）

        // ── 底栏 ──────────────────────────────────────────────
        // 底栏已移除：显示器状态改由侧栏圆点表达，
        // 素材数与自启状态在顶栏副标题和设置菜单里已有，
        // 全屏暂停提示由状态点的橙黄态取代。
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.isHidden = true
        fullscreenLabel.font = NSFont.systemFont(ofSize: 11)
        fullscreenLabel.isHidden = true




        // 宽度约束先建好（后面拖拽时改 constant）
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        rightWidthConstraint = right.widthAnchor.constraint(equalToConstant: rightWidth)
        rightTrailingConstraint = right.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -8)
        middleTrailingConstraint = middle.trailingAnchor.constraint(
            equalTo: right.leadingAnchor, constant: -8)
        // 折叠时中栏右缘要留出与展开态相同的呼吸空间。
        // 用 0 会让网格的 scroll（trailing 已外扩 8）把滚动条推到窗口外 ——
        // 表现成「滚动条不见了 / 挤在看不见的右侧」。
        middleTrailingCollapsed = middle.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -8)
        // 中栏宽度 = 窗口宽 - 左栏 - 右栏 - 间距（12+8+8+12）

        // ── 栏间拖拽条 ──
        let leftHandle = ResizeHandle()
        leftHandle.side = .leftPane
        leftHandle.translatesAutoresizingMaskIntoConstraints = false
        leftHandle.onDrag = { [weak self] dx in
            guard let self else { return }
            let newW = min(420, max(160, self.sidebarWidth + dx))
            self.sidebarWidth = newW
            self.sidebarWidthConstraint.constant = newW
            Settings.paneSidebarWidth = newW
            self.updateMiddleWidth()
            self.relayoutGridColumns()
        }

        let rightHandle = ResizeHandle()
        rightHandle.side = .rightPane
        rightHandle.translatesAutoresizingMaskIntoConstraints = false
        rightHandleView = rightHandle
        rightHandle.onDrag = { [weak self] dx in
            guard let self else { return }
            // 右栏向右拖 = 变窄，所以取反
            let newW = min(460, max(220, self.rightWidth - dx))
            self.rightWidth = newW
            self.rightWidthConstraint.constant = newW
            Settings.paneDetailWidth = newW
            self.updateMiddleWidth()
            // 右栏元素宽度跟着变（syncDetailDocSize 内部会重算）
            DispatchQueue.main.async { self.syncDetailDocSize() }
            self.relayoutGridColumns()
        }

        for v in [sidebar, middle, right, topBar, leftHandle, rightHandle] {
            container.addSubview(v)
        }

        // 通栏渐变模糊：横跨左中右三栏，位于所有内容之上、顶栏控件之下。
        //
        // 三栏各自有理由需要它：
        // - 左栏：列表滚动时元素会升到红绿灯那一行，有模糊层压着才不刺眼
        // - 中栏：网格缩略图从它下方穿过时自然虚化
        // - 右栏：顶部要让出位置给控件，也需要同一层底
        // 放在容器层而不是某一栏内部，才能一次覆盖三栏、边缘不会出现断层。
        let globalBlur = GradientMaskBlurView()
        globalBlur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(globalBlur, positioned: .above, relativeTo: nil)
        globalHeaderBlur = globalBlur
        libraryHeaderMask = globalBlur.sharedGradient
        NSLayoutConstraint.activate([
            globalBlur.topAnchor.constraint(equalTo: container.topAnchor),
            globalBlur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            globalBlur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            globalBlur.heightAnchor.constraint(equalToConstant: 72),
        ])

        // 顶栏控件必须浮在模糊层之上，否则会被它盖住。
        container.addSubview(topBar, positioned: .above, relativeTo: globalBlur)

        // 左栏的描边也要浮在模糊之上。
        //
        // 描边画在 sidebar 内部，而 globalBlur 是它的父容器之上的层 ——
        // 子视图的顺序无法超越父视图之上的兄弟，所以那一段描边会被糊掉。
        // 照片 App 的处理是：内容可以被顶栏虚化，但面板轮廓始终清晰。
        // 这里在容器层再画一份同样的描边，位置跟随左栏，压在模糊之上。
        let sidebarRimOverlay = GlassRimView()
        sidebarRimOverlay.cornerRadius = 16
        sidebarRimOverlay.usesFixedWhiteStroke = true
        sidebarRimOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebarRimOverlay, positioned: .above, relativeTo: globalBlur)
        NSLayoutConstraint.activate([
            sidebarRimOverlay.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarRimOverlay.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarRimOverlay.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRimOverlay.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])

        // 视图都进层级后再把标题绑到左栏右缘：
        // 跨视图约束若在 sidebar 加入层级前建立会崩。
        rebindTitleToSidebar()


        NSLayoutConstraint.activate([
            // 顶栏通栏：从左到右贯穿整个窗口。
            // 之前 left 绑在 sidebar.trailing，左侧品牌区不在浮层内，
            // 那片区域没有渐变模糊，与右侧割裂。
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            // 72 = 标题两行(34) + 淡出过渡区(38)
            topBar.heightAnchor.constraint(equalToConstant: 72),

            // ── 左栏：独立圆角面板 ──
            // 不再用分割线切分窗口，改成像 macOS 照片那样「嵌在窗口里的一个区域」：
            // 四周内缩 8pt、10pt 圆角、有自己的一层 liquid glass。
            // 侧栏从窗口顶端开始：红绿灯要嵌在面板内部，
            // 面板顶部留出 ~44pt 给它（内部列表再往下让位）。
            // 侧栏贴窗口左上角（内缩 0）。
            // 红绿灯由系统钉在距窗口左/上约 8pt，面板只要内缩就会把它们挤到外面；
            // 贴边后面板圆角自然把它们包住在内部的留白里（照片 App 的做法）。
            // 面板四周留边距（左/上各 12）：玻璃下面已有不透明垫底，
            // 不再依赖窗口背景，因此内缩是安全的。
            // 纵向三层：红绿灯(y8-24) → logo → 左栏面板
            // 左上角 12pt 边距由 logo 与面板共同体现
            // 面板内缩 8pt，与红绿灯的 8pt 偏置一致。
            //
            // 红绿灯由系统钉在距窗口左/上各 8pt 处。面板也从 8pt 开始后，
            // 按钮中心落在面板内的 (8,8)，距面板圆角圆心 (24,24) 约 11.3pt，
            // 小于圆角半径 16 —— 即按钮整个在圆角内部，不会被裁掉。
            // 之前误以为会被切而把面板顶到 0，结果按钮贴死了窗口边、没有留白。
            sidebar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            // 宽度可变：由拖拽条调整（约束存在属性里，拖动时改 constant）
            sidebarWidthConstraint,
            // 底部贴齐窗口：中栏是通铺的，左右栏若留 8pt 会显得「没铺满」
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            // ── 中栏：通铺，不圆角、不内缩 ──
            middle.topAnchor.constraint(equalTo: container.topAnchor),
            middle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
            middleTrailingConstraint,
            middle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // 中栏宽度 = 窗口宽 - 左栏 - 右栏 - 所有间距
            // 用精确约束而非 >=，否则拖宽右栏时总宽溢出会把窗口撑大

            // ── 右栏：独立圆角面板 ──
            // 右栏在顶栏浮层下方开始，留出可见的缝
            // 与左栏同高：顶栏已无背景，不再需要让位
            right.topAnchor.constraint(equalTo: container.topAnchor, constant: 84),
            rightTrailingConstraint,
            rightWidthConstraint,

            // ── 拖拽条：贴在栏间缝隙上 ──
            leftHandle.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 4),
            leftHandle.topAnchor.constraint(equalTo: sidebar.topAnchor),
            leftHandle.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            leftHandle.widthAnchor.constraint(equalToConstant: 10),

            rightHandle.centerXAnchor.constraint(equalTo: right.leadingAnchor, constant: -4),
            rightHandle.topAnchor.constraint(equalTo: right.topAnchor),
            rightHandle.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            rightHandle.widthAnchor.constraint(equalToConstant: 10),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        // 用空 wrapper 当 contentView：
        // contentView 直接用 DropZoneView：
        // 拖放接收必须在窗口的直接内容视图上才可靠（见 DropZoneView 注释）。
        // 窗口宽度问题由 contentMinSize/MaxSize 显式给出，不靠套 wrapper 解决。
        container.wantsLayer = true
        container.layer?.cornerRadius = 22
        container.layer?.masksToBounds = true
        w.contentView = container
        w.contentMinSize = NSSize(width: 900, height: 600)
        w.contentMaxSize = NSSize(width: 10000, height: 10000)

        w.delegate = self
        // 系统按钮位置就绪后再调（buildWindow 末尾会被布局重置，故延迟一轮）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.alignTrafficLights(w)
        }
        window = w

        // 窗口可缩放：列数随宽度变化，需要监听
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: w, queue: .main
        ) { [weak self] _ in
            // 缩放时布局还没落定，直接读 collection.bounds 会拿到旧宽度，
            // 算出的卡片偏大 → 这一帧是 4 列，下一帧又变 5 列，来回跳。
            // 推到下一轮 runloop，此时新宽度已生效，一次算准。
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateMiddleWidth()
                self.relayoutGridColumns()
                self.updateSearchForm()
                // 窗口缩放后 AppKit 会重置红绿灯位置，需要重新对齐。
                //
                // 但不能在这一帧对齐：拖动窗口边缘时布局与 AppKit 的按钮复位
                // 在同一帧内反复交替，直接改 frame 会看到按钮持续抖动。
                // 交给下一次 runloop，等本轮布局彻底落定再对齐一次。
                if let w = self.window {
                    DispatchQueue.main.async { self.alignTrafficLights(w) }
                }
            }
        }

        // 搜索框是窗口里第一个可聚焦控件，AppKit 会把它设为
        // initialFirstResponder，导致一启动它就处于编辑态；
        // 用户点界面任何地方都像在触碰输入框（反馈的「太容易触发」）。
        w.initialFirstResponder = nil
        installClickToEndEditing()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 必须等窗口真正成为 key window 之后再交还焦点：
        // 在 makeKeyAndOrderFront 之前/当行调用 makeFirstResponder(nil) 无效，
        // 那一刻窗口还不是 key，AppKit 随后仍会把焦点派给搜索框。
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            if win.firstResponder is NSTextView {
                win.makeFirstResponder(nil)
            }
        }
    }

    /// 给某块区域铺上毛玻璃，用透明度区分层次。
    ///
    /// 三档（越「靠后」的区域越透，越「靠前」越实）：
    ///   .sidebar           左导航 —— 最实，作为视觉基座
    ///   .headerView        顶栏 / 底栏 —— 中等
    ///   .underWindowBackground  中栏 / 右栏 —— 最透，让壁纸冷暖透上来
    ///
    /// 层次感靠两层叠加实现：毛玻璃本身 + 一层极淡的 tint。
    /// 只用 NSVisualEffectView 的话各区域看起来会一样平。
    private func addGlass(to host: NSView,
                          material: NSVisualEffectView.Material,
                          blending: NSVisualEffectView.BlendingMode = .behindWindow,
                          tint: CGFloat,
                          cornerRadius: CGFloat = 0) -> NSVisualEffectView {
        let blur = NSVisualEffectView()
        blur.material = material
        blur.blendingMode = blending
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.wantsLayer = true
        if cornerRadius > 0 {
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.masksToBounds = true
        }
        host.addSubview(blur, positioned: .below, relativeTo: nil)

           // liquid glass 的描边：一条贴着圆角的细高光。
           // 只靠半透明填充时面板会「糊」在底色上、没有边界感；
           // 系统这套玻璃的做法是在内侧描一圈渐变高光 ——
           // 上边亮、下边暗，模拟光从上方来的折射。
           if cornerRadius > 0 {
               let rim = GlassRimView()
               rim.cornerRadius = cornerRadius
               rim.translatesAutoresizingMaskIntoConstraints = false
               host.addSubview(rim)
               NSLayoutConstraint.activate([
                   rim.topAnchor.constraint(equalTo: host.topAnchor),
                   rim.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                   rim.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                   rim.bottomAnchor.constraint(equalTo: host.bottomAnchor),
               ])
           }
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: host.topAnchor),
            blur.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // 层次感的第二层：极淡 tint，越实的区域 tint 越重
        if tint > 0 {
            let t = NSView()
            t.wantsLayer = true
            t.layer?.backgroundColor = NSColor(white: 0, alpha: tint).cgColor
            t.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(t)
            NSLayoutConstraint.activate([
                t.topAnchor.constraint(equalTo: blur.topAnchor),
                t.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                t.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                t.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
        }
        return blur
    }

    /// 单像素分隔线。
    ///
    /// 不用 NSBox(.separator)：它本质是带描边的盒子，当竖线用（宽 1pt）时
    /// 左右两条描边都会被画出来，视觉上就成了「双线」—— 用户反馈「看起来像
    /// 每个区域用了两条线分开」。这里直接铺一条 1pt 的纯色视图。
    private func hairline(vertical: Bool) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        // 用「不透明的中间灰」：半透明白会透到下一层窗口（看起来像没画），
        // 而且白色叠在深色玻璃上会变成脏灰。取比背景略亮、又不刺眼的灰度。
        v.layer?.backgroundColor = NSColor(srgbRed: 0.34, green: 0.35, blue: 0.37, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return v
    }

    /// 让输入框符合本 App 的圆角语言。
    ///
    /// AppKit 的 .roundedBezel 在大尺寸下仍然是「方角 + 内嵌阴影」，
    /// 和其余全部圆角的界面不搭。这里关掉 bezel、自绘圆角背景 +
    /// 1pt 描边，并在获得焦点时把描边换成强调色。
    private func styleRoundedField(_ field: NSTextField,
                                   height: CGFloat = 26,
                                   inset: CGFloat = 7) {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 7
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        field.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        field.cell?.sendsActionOnEndEditing = true

        // 关掉 border 后 NSTextField 失去原生高度，不显式设置会被压扁。
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: height).isActive = true

        if let cell = field.cell as? VerticallyCenteredFieldCell {
            cell.wraps = false
            cell.isScrollable = true
            // 左右内边距：自绘圆角框时文字会贴边
            cell.horizontalInset = inset
        }
    }

/// 不参与命中测试的 NSVisualEffectView。
/// 作为按钮的圆底时，它铺满整个按钮；不穿透的话点击全被它吃掉。
final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 不参与命中测试的 NSImageView，理由同上（图标盖在按钮中心）。
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 圆形 LiquidGlass 按钮。
///
/// 圆底是真正的 NSVisualEffectView（.popover），不是半透明色块，
/// 所以能透出背后内容并有真实模糊。
///
/// 两个子视图都改用 Passthrough 版本：否则点击落在图标或材质上时，
/// 事件被子视图吃掉、按钮收不到，表现为「点了没反应」。
/// 注意**不要**覆盖按钮自身的 hitTest —— 那会破坏 NSButton 的追踪逻辑。
final class CircleGlassButton: NSButton {
    var diameter: CGFloat = 34

    private let backing = PassthroughEffectView()
    private let iconView = PassthroughImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        common()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        common()
    }

    private func common() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .noImage
        wantsLayer = true

        backing.material = .popover
        backing.blendingMode = .withinWindow
        backing.state = .active
        backing.translatesAutoresizingMaskIntoConstraints = false
        backing.wantsLayer = true
        backing.layer?.masksToBounds = true
        backing.layer?.borderWidth = 0.65
        backing.layer?.borderColor = NSColor.white.withAlphaComponent(0.42).cgColor
        addSubview(backing)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white
        addSubview(iconView)

        NSLayoutConstraint.activate([
            backing.centerXAnchor.constraint(equalTo: centerXAnchor),
            backing.centerYAnchor.constraint(equalTo: centerYAnchor),
            backing.widthAnchor.constraint(equalToConstant: diameter),
            backing.heightAnchor.constraint(equalToConstant: diameter),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func setSymbol(_ name: String, pointSize: CGFloat = 15) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        backing.layer?.cornerRadius = d / 2
        backing.alphaValue = isEnabled ? 1.0 : 0.55
    }
}
    // MARK: 顶栏

    /// 把按钮配置成圆形 LiquidGlass 样式。
    private func styleCircleButton(_ button: NSButton,
                                   symbol: String,
                                   tooltip: String,
                                   diameter: CGFloat = 34) {
        if let circle = button as? CircleGlassButton {
            circle.diameter = diameter
            circle.setSymbol(symbol)
        } else {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.contentTintColor = .white
        }
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false

        let w = button.widthAnchor.constraint(equalToConstant: diameter)
        let h = button.heightAnchor.constraint(equalToConstant: diameter)
        w.priority = .required
        h.priority = .required
        w.isActive = true
        h.isActive = true
    }

    /// 给圆形按钮垫一层真实的模糊材质。
    /// 直接给 button 设 backgroundColor 只是半透明色块，没有模糊。
    private func glassBacking(for button: NSButton, diameter: CGFloat = 30) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = diameter / 2
        v.layer?.masksToBounds = true
        return v
    }

    private func buildTopBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        // 顶栏自带渐变模糊底：横跨整个窗口（含右栏区域），
        // 这样搜索/加号/齿轮/折叠这些控件浮在同一条模糊带上，
        // 而不是各自飘在透明背景里。
        //
        // 它还解决了另一个问题：右栏折叠后，右栏顶部会露出一块没有模糊的区域，
        // 与中栏的浮栏形成割裂 —— 顶栏通栏模糊之后那块也被覆盖。
        // 用自同步渐变层：遮罩在 layout() 里永远与自身等大。
        // 之前手工调 syncTopBarMask() 只在 refreshControls 里跑过一次，
        // 那时顶栏还没布局完（bounds 为 0），遮罩停在 0x0，
        // 所有模糊都被裁掉，看起来就只剩一层薄底色。
        // 顶栏不再自建模糊层：模糊必须放在中栏内部才能采到缩略图
        // （见 buildLibraryPane 里的 headerBlur）。
        // 这里只保留文字与按钮，它们的底由中栏那层模糊透上来。

        // 不再叠任何 tint。
        //
        // 之前用白色半透明矩形做「提亮」，那本质上仍是一个白方框盖上去，
        // 模糊被它冲淡成灰雾 —— 看起来像「透明度渐变」而不是「模糊渐变」。
        // 真正的做法只有一条：让 NSVisualEffectView 自己模糊，
        // 用渐变遮罩控制模糊可见的范围，中间不插任何实色层。

        // 标题：当前分类 + 素材数（浮在图库之上，无背景）
        let title = NSTextField(labelWithString: "")

        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        // 白底只有 55% 透明度，叠在深色模糊层上整体仍是深灰，
        // 深色文字在这个底上对比不足、糊成一片。
        // 用浅色文字 + 更实的白底，既亮又清楚。
        title.textColor = NSColor.white.withAlphaComponent(0.98)
        // 模糊后的底色不可控（缩略图有亮有暗），白字落在浅色图上会失对比。
        // 加一层极淡的深色阴影做兜底 —— 比再叠一层实色背景轻得多，
        // 也不会把模糊重新盖成灰雾。
        title.shadow = Self.headerTextShadow()
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.72)
        subtitle.shadow = Self.headerTextShadow()
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // 搜索框
        searchField.placeholderString = L10n.t("top.searchPlaceholder")
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.isBordered = false
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 14
        searchField.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        // 换成垂直居中的 cell（保留放大镜与清除按钮）
        let searchCell = VerticallyCenteredSearchCell()
        searchCell.alignment = .center
        searchCell.placeholderString = L10n.t("top.searchPlaceholder")
        searchField.cell = searchCell
        searchField.alignment = .center
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // 占位约束：只在「还没绑定到右栏左缘」的极短时间里起作用。
        // 优先级必须低 —— 它是个固定 700pt 的偏移，一行加到右边那串
        // 按钮的约束上，总和会超出窗口宽度；折叠右栏后更明显：
        // 三个按钮被整条推到窗口外，用户再也点不到它们（实测如此）。
        searchPlaceholderConstraint = searchField.leadingAnchor.constraint(
            equalTo: bar.leadingAnchor, constant: 700)
        searchPlaceholderConstraint.priority = .init(250)
        // ── 圆形按钮：返回 / 列数 / 样式 / 搜索 / 加号 / 齿轮 / 折叠 ──
        styleCircleButton(backButton, symbol: "chevron.left",
                          tooltip: L10n.t("top.back"))
        backButton.target = self
        backButton.action = #selector(goBackFolder)

        styleCircleButton(colMinusButton, symbol: "minus",
                          tooltip: L10n.t("top.fewerColumns"))
        colMinusButton.target = self
        colMinusButton.action = #selector(stepColumnsDown)

        styleCircleButton(colPlusButton, symbol: "plus",
                          tooltip: L10n.t("top.moreColumns"))
        colPlusButton.target = self
        colPlusButton.action = #selector(stepColumnsUp)

        styleCircleButton(gridStyleButton, symbol: "square.grid.2x2",
                          tooltip: L10n.t("top.gridStyle"))
        gridStyleButton.target = self
        gridStyleButton.action = #selector(toggleGridStyle)

        styleCircleButton(searchToggleButton, symbol: "magnifyingglass",
                          tooltip: L10n.t("top.search"))
        searchToggleButton.target = self
        searchToggleButton.action = #selector(expandSearch)

        styleCircleButton(addFilesButton, symbol: "plus",
                          tooltip: L10n.t("win.addFiles"))
        addFilesButton.target = self
        addFilesButton.action = #selector(addFiles)

        styleCircleButton(settingsButton, symbol: "gearshape",
                          tooltip: L10n.t("top.settings"))
        settingsButton.target = self
        settingsButton.action = #selector(showSettingsMenu)

        styleCircleButton(collapseButton, symbol: "sidebar.right",
                          tooltip: L10n.t("win.toggleDetail"))
        collapseButton.target = self
        collapseButton.action = #selector(toggleDetailPane)

        // 搜索框：展开态宽度由约束驱动，不写死数值
        searchField.isHidden = true
        searchWidthConstraint = searchField.widthAnchor.constraint(equalToConstant: 180)

        // 标题组：返回按钮 + 两行文字。rebindTitleToSidebar 会把整组绑到左栏右缘。
        let titleText = NSStackView(views: [title, subtitle])
        titleText.orientation = .vertical
        titleText.alignment = .leading
        titleText.spacing = 1
        titleText.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [backButton, titleText])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRowStack = titleRow

        // 工具区：搜索放最右。
        //
        // 搜索框展开时宽度会变化；若它在中间，右侧按钮会被反复推挤 ——
        // 放到末尾后，其余按钮位置恒定，只有搜索自身伸缩。
        let tools = NSStackView(views: [colMinusButton, colPlusButton, gridStyleButton,
                                        addFilesButton, settingsButton, collapseButton,
                                        searchToggleButton, searchField])
        tools.orientation = .horizontal
        tools.alignment = .centerY
        tools.spacing = 8
        tools.translatesAutoresizingMaskIntoConstraints = false
        toolsStack = tools

        bar.addSubview(titleRow)
        bar.addSubview(tools)
        self.topTitle = title
        self.topTitleView = title
        self.topBarHost = bar
        self.topSubtitle = subtitle

        NSLayoutConstraint.activate([
            // 标题行：初始占位，稍后 rebindTitle 会绑到左栏右缘
            titleRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 200),
            // 浮栏内容垂直位置：47 → 22（上移 25）→ 30（下移 8）
            titleRow.centerYAnchor.constraint(equalTo: bar.topAnchor, constant: 30),

            // 工具区贴右缘，垂直居中
            tools.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            tools.centerYAnchor.constraint(equalTo: bar.topAnchor, constant: 30),

            // 搜索框展开态：与按钮同高
            searchField.heightAnchor.constraint(equalToConstant: 30),
            searchWidthConstraint!,
        ])
        return bar
    }

    // MARK: 浮栏按钮动作

    /// 返回上一级目录。根目录时按钮本来就隐藏，这里再兜一层。
    @objc private func goBackFolder() {
        guard let cur = libraryFilter, !cur.isEmpty else { return }
        // 只支持一层子目录，所以上一级就是根目录。
        // 仍按「最后一个 / 之前」来算，将来支持多级时不用改这里。
        let parent: String?
        if let i = cur.lastIndex(of: "/") {
            parent = String(cur[cur.startIndex..<i])
        } else {
            parent = nil
        }
        sidebarSelectionChanged(.library(parent))
        sidebar.select(.library(parent))
    }

    /// 列数档位（与照片 App 一致：3 / 5 / 7 / 9）。
    private static let columnSteps = [3, 5, 7, 9]

    /// 把任意值夹到最近的合法档位。
    ///
    /// 不能用 `firstIndex(of:)` + `guard let` —— 一旦设置里存了非档位值
    /// （手动 defaults write、旧版本残留等），索引为 nil，动作直接静默返回，
    /// 表现就是「按钮点上去完全没反应」，而不是报错。
    private func nearestStep(_ n: Int) -> Int {
        Self.columnSteps.min(by: { abs($0 - n) < abs($1 - n) }) ?? 5
    }

    /// 缩小视图 = 缩略图变小 = 列数 +2（照片 App 的减号）
    @objc private func stepColumnsDown() {
        let cur = nearestStep(Settings.gridColumnCount)
        let next = Self.columnSteps.first(where: { $0 > cur }) ?? Self.columnSteps.last!
        setColumnCount(next)
    }

    /// 放大视图 = 缩略图变大 = 列数 -2（照片 App 的加号）
    @objc private func stepColumnsUp() {
        let cur = nearestStep(Settings.gridColumnCount)
        let next = Self.columnSteps.last(where: { $0 < cur }) ?? Self.columnSteps.first!
        setColumnCount(next)
    }

    private func setColumnCount(_ n: Int) {
        Settings.gridColumnCount = n
        relayoutGridColumns()
        // relayoutGridColumns 里若 rows 没变，setGrid 会被跳过，
        // 此时卡片尺寸变了但网格布局没重建，需要显式重排一次。
        thumbnailGrid.reloadFilteredStyle()
        refreshHeaderButtons()
    }

    /// 网格样式切换：间距网格 ↔ 正方形填充
    @objc private func toggleGridStyle() {
        Settings.gridSquareFill.toggle()
        ThumbnailItem.fillsSquare = Settings.gridSquareFill
        // 圆角与填充模式都要让已存在的卡片重画
        for item in thumbnailGrid.visibleCards() {
            item.refreshCardSize()
        }
        thumbnailGrid.reloadFilteredStyle()
        refreshHeaderButtons()
    }

    /// 展开搜索框（从圆钮态）
    @objc private func expandSearch() {
        searchExpanded = true
        applySearchExpansion(animated: false)
        window?.makeFirstResponder(searchField)
    }

    /// 让搜索在「圆钮」与「展开输入框」之间切换。
    ///
    /// 只用同一个 NSSearchField 切换可见性，不做两个独立控件 ——
    /// 两者在临界宽度上互相触发显隐会闪。
    private func applySearchExpansion(animated: Bool) {
        searchField.isHidden = !searchExpanded
        searchToggleButton.isHidden = searchExpanded
        // 展开后宽度跟随可用空间，收起时不参与布局
        searchWidthConstraint?.isActive = searchExpanded
        if searchExpanded {
            // 宽度 = 工具区剩余空间，且不小于 140：
            // 太窄就没有输入价值，那时不如显示圆钮。
            let minW: CGFloat = 140
            searchWidthConstraint?.constant = minW
        }
        refreshHeaderButtons()
    }

    /// 按当前可用宽度决定搜索是「圆钮」还是「展开的长条」。
    ///
    /// 判据是工具区左侧还剩多少空间。少于 minWidth 就收起 ——
    /// 照片 App 也是这个逻辑：窗口不够宽时搜索先让位，
    /// 因为圆钮始终可点，而被压扁的输入框既看不见也打不了字。
    private func updateSearchForm() {
        guard let tools = toolsStack, let row = titleRowStack else { return }
        let available = tools.frame.minX - (row.frame.maxX + 16)
        let minWidth: CGFloat = 140
        let shouldExpand = available >= minWidth + 8

        // 只有「用户主动展开过」或「宽度足够」才展开；
        // 宽度不足时无论之前什么状态都收起，避免搜索框被压成一条。
        if !shouldExpand {
            if searchExpanded {
                searchExpanded = false
                applySearchExpansion(animated: false)
            }
            return
        }
        if searchExpanded {
            searchWidthConstraint?.constant = available - 8
        }
    }

    /// 同步浮栏按钮的可用状态与图标。
    private func refreshHeaderButtons() {
        // 返回按钮常驻：根目录时置灰而不是隐藏。
        //
        // 隐藏会让标题左右跳动（按钮占 34pt + 间距 8），
        // 每次进出文件夹标题都位移一次，观感不稳定。
        // 常驻 + 禁用能让标题位置恒定，也顺带告知「这里已经到头了」。
        let canGoBack = !(libraryFilter ?? "").isEmpty
        backButton.isEnabled = canGoBack
        backButton.alphaValue = canGoBack ? 1.0 : 0.35

        // 列数到达边界时置灰（不隐藏，保持位置稳定）
        // 语义按「视图缩放」：加号放大视图=列数减少，减号缩小=列数增加。",
        // 因此列数已在最小档时加号该禁用（无法再放大），反之亦然。
        // 用夹紧后的档位判断，避免设置里存了非法值时两个按钮都被禁用。
        let cur = nearestStep(Settings.gridColumnCount)
        colPlusButton.isEnabled = cur > Self.columnSteps.first!
        colMinusButton.isEnabled = cur < Self.columnSteps.last!

        // 样式按钮图标反映「当前模式」，而非「点了会变成什么」
        let fill = Settings.gridSquareFill
        (gridStyleButton as? CircleGlassButton)?.setSymbol(
            fill ? "square.grid.3x3.fill" : "square.grid.2x2")
    }

    // MARK: 中栏（图库）

    private func buildLibraryPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        // 中栏即底层本身：不额外叠玻璃。
        // 底层（container 的 baseBlur）已经铺满整窗并模糊了桌面壁纸，
        // 中栏直接暴露它 —— 这才是「内嵌在底层」的语义。
        // 若再叠一层，等于对同一块内容做两次玻璃处理，
        // 与左右栏（底层 + 各自一层）不一致，视觉上会割裂。
        pane.wantsLayer = true

        addButton.title = L10n.t("win.addFiles")
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(addFiles)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        // 添加按钮不再放中栏顶部：用户更倾向直接拖入图片。
        // 按钮移到底部区域（见 buildDetailPane 末尾）。
        let toolbar = NSStackView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 启动环境色采样：读当前壁纸的主色，作为侧栏描边的染色源。
        // 采样频率 1.5s，解码缩略图 32px，开销可忽略。
        AmbientColorSampler.shared.wallpaperPathProvider = { [weak self] in
            guard let self else { return nil }
            // 取当前任意一块屏正在显示的壁纸 —— 它们的色调就是窗口周围的环境
            return self.state.assignment.values.first
        }
        AmbientColorSampler.shared.start(points: [])

        // 网格尺寸变化后重算列宽（启动时布局一完成就能得到 5 列，
        // 不必等用户缩放窗口）
        thumbnailGrid.onGeometryChange = { [weak self] in
            self?.relayoutGridColumns()
        }

        thumbnailGrid.onSelect = { [weak self] path in self?.selectFromGrid(path: path) }
        thumbnailGrid.onContextMenu = { [weak self] path, view in
            self?.makeCardMenu(path: path, view: view)
        }
        // 中栏空白处右键：库级操作（刷新 / 添加 / 在访达显示）
        thumbnailGrid.onBlankContextMenu = { [weak self] view in
            self?.makeBlankMenu(view: view)
        }
        thumbnailGrid.onDoubleClick = { [weak self] path in
            guard let self,
                  let idx = self.state.library.firstIndex(where: { $0.path == path }) else { return }
            StateStore.shared.update { st in st.lastSelectedItem = path }
            self.refreshControls()
        }
        thumbnailGrid.translatesAutoresizingMaskIntoConstraints = false

        // 空库引导卡片：把「壁纸从哪来、怎么进来、怎么用上」讲清楚。
        // 库为空时始终显示 —— 不做「下次不再提示」的持久化状态，
        // 因为用户清空库后回到这个状态本来就该重新看到引导。
        let emptyCard = makeEmptyStateCard()
        emptyCard.isHidden = true
        libraryEmptyLabel = emptyCard

        // 中栏顶部不再自建模糊带：顶栏已经通栏覆盖了整个窗口宽度，
        // 再叠一层就是两层模糊叠在一起，交界处会明显变暗。
        // 标题改由顶栏承载（见 buildTopBar 里的 libraryTitle）。

        // 导入进行中的浮标：压在中栏右上角，不参与布局，
        // 因此不会挤动网格；导入结束后消失，不留下空位。
        let banner = makeImportBanner()
        importBanner = banner

        // 顶栏模糊必须放在**中栏内部**、网格之上。
        //
        // NSVisualEffectView 只采样同一图层树中、位于它之下的内容。
        // 顶栏和中栏是兄弟视图，放在顶栏里的模糊看不到中栏的缩略图 ——
        // 实测：去掉遮罩后顶栏依然完全不模糊，证明问题在采样范围而非遮罩。
        // 放进中栏后，它下面的网格就是可见的采样源。
        // 顶栏渐变模糊已提到容器层（见 buildWindow），
        // 这样它才能横跨三栏、同时模糊左栏滚动内容与中栏网格。
        for v in [toolbar, thumbnailGrid, emptyCard, banner] { pane.addSubview(v) }

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
        ])

        NSLayoutConstraint.activate([
            // 添加按钮移到底部（用户更希望直接拖入图片），这里只留 0 高度占位
            toolbar.topAnchor.constraint(equalTo: pane.topAnchor, constant: 0),
            toolbar.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),

            // 图库从 pane 顶部开始：图片可以滚动到顶部的渐变模糊层下方
            thumbnailGrid.topAnchor.constraint(equalTo: pane.topAnchor),
            thumbnailGrid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            // 与右栏保持一致：内容自然贴边、不做外扩，
            // 滚动条到边缘的距离交给 AppKit 的 overlay 默认表现。
            thumbnailGrid.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            thumbnailGrid.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            emptyCard.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            emptyCard.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            emptyCard.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        // 顶部内边距：避让顶部的渐变模糊层（图库本身可以滚到它下面）
        // 比顶栏高度多留 28：图片滚到顶栏下方时，
        // 上方的渐变模糊才有作用空间（否则第一行紧贴边缘，看不出淡出）
        // 顶栏已无背景，只需让出标题行的高度（logo 中心 47 + 少量留白）
        // 内容初始位置要让开顶栏浮层，避免首行一进来就被模糊掉。
        //
        // 之前设 0 是为了「让模糊看得见」——但那样首行永远被压在半透明带里，
        // 视觉上像还没加载完。正确行为是照片 App 那样：
        // 初始状态整齐地停在浮栏下方，**向下滚动时**内容才穿进模糊带淡出。
        // 浮栏高 72，留 60：首行完整露出，并紧贴浮栏下缘（用户再微调 -8pt）。
        thumbnailGrid.setTopContentInset(60)
        // 图库在顶部 100pt 内渐隐，替代「顶栏模糊」（顶栏是兄弟视图，
        // 玻璃采不到它的内容，只能让图库自己淡出）
        // thumbnailGrid.setTopFade(height: 100)   // 临时禁用，验证滚动

        return pane
    }

    // MARK: 右栏（详情）

    private func buildDetailPane() -> NSView {
        let pane = NSView()
        self.detailPane = pane
        pane.translatesAutoresizingMaskIntoConstraints = false
        // 右栏：比中栏略实一点，因为它承载控件、需要更好的可读性
        // 右栏：独立圆角面板，用 .sidebar 材质做 liquid glass
        // 右栏：中等层——比左栏透一点，但比中栏实（承载滑块输入框）
        pane.wantsLayer = true
        // 与左栏一致的材质层：.popover ≈ SwiftUI 的 .regularMaterial，
        // 只柔化、不压暗。此前这里是个透明视图，靠底层 baseBlur 透上来，
        // 结果右栏看起来「没有材质」，与左栏也不统一。
        let rightTint = NSVisualEffectView()
        rightTint.material = .popover
        rightTint.blendingMode = .withinWindow
        rightTint.state = .active
        rightTint.translatesAutoresizingMaskIntoConstraints = false
        rightTint.wantsLayer = true
        rightTint.layer?.cornerRadius = 16
        rightTint.layer?.masksToBounds = true
        pane.addSubview(rightTint)

        // 与左栏一致的环境染色层（AppKit 材质不会自己取色，需补这一层）。
        let rightWash = PassthroughLayerView()
        rightWash.wantsLayer = true
        rightWash.translatesAutoresizingMaskIntoConstraints = false
        rightWash.layer?.cornerRadius = 16
        rightWash.layer?.masksToBounds = true
        pane.addSubview(rightWash)
        NSLayoutConstraint.activate([
            rightWash.topAnchor.constraint(equalTo: pane.topAnchor),
            rightWash.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            rightWash.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            rightWash.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        rightWash.layer?.backgroundColor = AmbientColorSampler.shared.color
            .withAlphaComponent(0.14).cgColor
        AmbientColorSampler.shared.observe { [weak rightWash] c in
            rightWash?.layer?.backgroundColor = c.withAlphaComponent(0.14).cgColor
        }
        NSLayoutConstraint.activate([
            rightTint.topAnchor.constraint(equalTo: pane.topAnchor),
            rightTint.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            rightTint.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            rightTint.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        // 描边
        let rightRim = GlassRimView()
        rightRim.cornerRadius = 16
        rightRim.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(rightRim)
        NSLayoutConstraint.activate([
            rightRim.topAnchor.constraint(equalTo: pane.topAnchor),
            rightRim.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            rightRim.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            rightRim.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        // pane 自身也裁圆，否则子视图（滚动区）会把圆角盖掉
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 16
        pane.layer?.masksToBounds = true

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        // 右侧留 0：滚动条叠在 clip view 上，若 root 还有 16pt 右内边距，
        // 滚动条会被推到离 pane 边缘 18pt 处（实测），与中栏的 3pt 明显不一致。
        // 改成 0 后滚动条贴到与中栏相同的位置，文字与滚动条之间的呼吸由内容自身留白提供。
        // 顶部留出顶栏高度（76），因为顶栏现在是浮层
        // 元素上移：顶栏已无背景，不再需要较大的顶部内边距
        // 四边都留 16：right 为 0 时预览图等元素会直接贴到右边缘
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        // 不在这里定 translatesAutoresizingMaskIntoConstraints：
        // 右栏的 root 由 syncDetailDocSize 用 frame 摆放，
        // 在 doc.addSubview 处统一设为 true。

        // 显示器信息

        // 文件名标题：与预览图同宽，字号与之前的「全部显示器」一致
        paneTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        // 单行 + 中间截断：文件名常有长 UUID 或哈希，截中间比截尾更容易认。
        // 必须显式单行，否则会换行把下面的预览图挤走。
        paneTitle.lineBreakMode = .byTruncatingMiddle
        paneTitle.maximumNumberOfLines = 1
        paneTitle.cell?.wraps = false
        paneTitle.cell?.isScrollable = false
        paneTitle.translatesAutoresizingMaskIntoConstraints = false
        // 允许被压缩：优先级降到 250，窗口变窄时标签跟着缩，不会顶出面板。
        paneTitle.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let fileTitleW = paneTitle.widthAnchor.constraint(equalToConstant: 270)
        fileTitleW.priority = .init(700)
        detailWidthConstraints.append(fileTitleW)
        fileTitleW.isActive = true
        root.addArrangedSubview(paneTitle)

        // 当前素材的大图预览：给"选中了什么"一个明确的视觉锚点
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        previewPane.heightAnchor.constraint(equalToConstant: 150).isActive = true
        // 宽度由 syncDetailDocSize 写入（跟随栏宽减左右内边距）
        let previewPaneW = previewPane.widthAnchor.constraint(equalToConstant: 270)
        previewPaneW.priority = .init(999)
        detailWidthConstraints.append(previewPaneW)
        previewPaneW.isActive = true
        // 预览图必须严格等于内容宽度，否则窄栏时会顶出面板
        previewPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewPane.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        root.addArrangedSubview(previewPane)

        root.addArrangedSubview(separator(width: 270))


        // 壁纸文件详情：文件名 / 分辨率 / 大小 / 分类 / 位置。
        // 这些是只读信息，用多行标签呈现，不占额外的行高。
        let infoTitle = NSTextField(labelWithString: L10n.t("detail.fileInfo"))
        infoTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        infoTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(infoTitle)

        fileInfoLabel.font = NSFont.systemFont(ofSize: 10.5)
        fileInfoLabel.textColor = .secondaryLabelColor
        // 按字符换行 + 不限行数：长文件名宁可折到下一行，也不要被截断或顶出面板。
        // （之前是「中间截断 + 最多 5 行」，行数一满就被截，但宽度不够时又会溢出。）
        fileInfoLabel.lineBreakMode = .byCharWrapping
        fileInfoLabel.maximumNumberOfLines = 0
        fileInfoLabel.cell?.wraps = true
        fileInfoLabel.cell?.isScrollable = false
        fileInfoLabel.preferredMaxLayoutWidth = 270
        fileInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        fileInfoLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let fileInfoLabelW = fileInfoLabel.widthAnchor.constraint(equalToConstant: 270)
        fileInfoLabelW.priority = .init(700)
        detailWidthConstraints.append(fileInfoLabelW)
        fileInfoLabelW.isActive = true
        root.addArrangedSubview(fileInfoLabel)

        root.addArrangedSubview(separator(width: 270))

        // 构图
        let compTitle = NSTextField(labelWithString: L10n.t("detail.framing"))
        compTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        compTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(compTitle)

        framingSummary.font = NSFont.systemFont(ofSize: 11)
        framingSummary.textColor = .tertiaryLabelColor
        framingSummary.maximumNumberOfLines = 0
        framingSummary.lineBreakMode = .byWordWrapping
        framingSummary.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(framingSummary)

        for (i, m) in ScaleMode.allCases.enumerated() {
            modePopup.addItem(withTitle: m.label)
            if i == 0 { modePopup.selectItem(at: 0) }
        }
        modePopup.target = self
        modePopup.action = #selector(adjustmentChanged)
        root.addArrangedSubview(compactRow(L10n.t("win.scaleMode"), modePopup))

        zoomSlider.target = self
        zoomSlider.action = #selector(adjustmentChanged)
        root.addArrangedSubview(compactSliderRow(L10n.t("win.zoom"), zoomSlider, zoomValue))

        offXSlider.target = self
        offXSlider.action = #selector(adjustmentChanged)
        root.addArrangedSubview(compactSliderRow(L10n.t("win.offsetX"), offXSlider, offXValue))

        offYSlider.target = self
        offYSlider.action = #selector(adjustmentChanged)
        root.addArrangedSubview(compactSliderRow(L10n.t("win.offsetY"), offYSlider, offYValue))

        // 静音是**全局开关**（作用于所有视频壁纸），与「某屏 × 某图」的
        // 构图调整不是一类东西，所以单独一个 action。
        // 共用 adjustmentChanged 会让它被构图那条路径的刷新覆盖。
        // 播放速度：只对视频有意义。分段控件比四个单选按钮紧凑，
        // 也不引入额外的子菜单层级。
        rateControl.target = self
        rateControl.action = #selector(rateChanged)
        rateControl.controlSize = .small
        rateControl.segmentStyle = .rounded
        rateControl.translatesAutoresizingMaskIntoConstraints = false
        rateControl.selectedSegment = 1   // 默认 1×

        let rateTitle = NSTextField(labelWithString: L10n.t("win.playbackRate"))
        rateTitle.font = NSFont.systemFont(ofSize: 11)
        rateTitle.textColor = .secondaryLabelColor
        rateTitle.alignment = .left

        // 自定义输入：预设四档之外还想用 0.8× 这类值时有个去处。
        // 复用与缩放/偏移相同的数值框样式，保证视觉一致。
        rateField.cell = VerticallyCenteredFieldCell()
        rateField.isEditable = true
        rateField.isSelectable = true
        rateField.alignment = .right
        styleRoundedField(rateField, height: 22, inset: 5)
        rateField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rateField.target = self
        rateField.action = #selector(rateFieldCommitted)
        rateField.delegate = self
        rateField.translatesAutoresizingMaskIntoConstraints = false
        rateField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        // 分段控件吃掉剩余宽度、输入框定宽，整行跟着栏宽伸缩。
        // 不给分段控件加宽约束的话，NSStackView 会把它压到最小固有宽度，
        // 右侧留出一大片空白，与上面几条滑块行的视觉节奏对不上。
        // NSSegmentedControl 的固有宽度不会被 stack 拉开（hugging 优先级对它无效），
        // 想让每段等分整行，只能给一个「等宽」的强约束。
        rateControl.segmentDistribution = .fillEqually
        rateControl.setContentHuggingPriority(.init(1), for: .horizontal)
        rateControl.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let rateControls = NSStackView(views: [rateControl, rateField])
        rateControls.orientation = .horizontal
        rateControls.alignment = .centerY
        rateControls.spacing = 8
        rateControls.translatesAutoresizingMaskIntoConstraints = false

        // 标题单独放进一个左对齐容器：
        // 竖栈用 .width 之后子视图会等宽铺满，NSTextField 会把自己的文字居中，
        // 「播放速度」就跑到右半边去了。包一层让标题留在左边。
        let titleRow = NSStackView(views: [rateTitle])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        rateTitle.setContentHuggingPriority(.init(1), for: .horizontal)

        let rateStack = NSStackView(views: [titleRow, rateControls])
        rateStack.orientation = .vertical
        // .width 让竖栈里的子视图与栈等宽（.leading 只会贴左、不拉伸），
        // 这样分段控件和输入框才会跟随栏宽。
        rateStack.alignment = .width
        rateStack.spacing = 6
        rateStack.translatesAutoresizingMaskIntoConstraints = false

        // 与滑块行一致：宽度跟随栏宽（由 syncDetailDocSize 更新 constant）
        let rowW = rateStack.widthAnchor.constraint(equalToConstant: 270)
        detailWidthConstraints.append(rowW)
        // 整行铺满：分段控件吃掉除输入框外的全部宽度。
        // 只让外层 stack 等宽不够 —— NSStackView 内部的水平栈仍需知道
        // 谁该被拉伸，否则两个子视图都保持固有宽度、中间空出一块。
        let ctrW = rateControls.widthAnchor.constraint(equalTo: rateStack.widthAnchor)
        ctrW.priority = .init(999)
        ctrW.isActive = true
        // 分段控件吃满「容器宽 - 输入框宽 - 间距」
        let segW = rateControl.widthAnchor.constraint(
            equalTo: rateControls.widthAnchor, constant: -(56 + 8))
        segW.isActive = true

        rateRow = rateStack
        root.addArrangedSubview(rateStack)

        muteCheck.target = self
        muteCheck.action = #selector(muteChanged)
        muteCheck.state = state.muted ? .on : .off
        // 复选框必须能接收点击：父视图若拦截了 hitTest，按钮就点不动。
        muteCheck.isEnabled = true
        muteCheck.refusesFirstResponder = false
        root.addArrangedSubview(muteCheck)

        root.addArrangedSubview(separator(width: 270))

        // 操作
        let opTitle = NSTextField(labelWithString: L10n.t("detail.actions"))
        opTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        opTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(opTitle)

        // 预设的「加载」按钮。此前只在 showPresetDetail 里设了 isHidden=false，
        // 但这个按钮从未被加入视图层级，所以永远不会出现 —— 预设无法应用的根因。
        loadPresetButton.title = L10n.t("preset.load")
        loadPresetButton.bezelStyle = .rounded
        loadPresetButton.target = self
        loadPresetButton.action = #selector(loadSelectedPresetFromButton)
        loadPresetButton.translatesAutoresizingMaskIntoConstraints = false
        let loadPresetButtonW = loadPresetButton.widthAnchor.constraint(equalToConstant: 270)
        loadPresetButtonW.priority = .init(700)
        detailWidthConstraints.append(loadPresetButtonW)
        loadPresetButtonW.isActive = true
        loadPresetButton.isHidden = true
        root.addArrangedSubview(loadPresetButton)

        assignButton.title = L10n.t("win.setWallpaper")
        assignButton.bezelStyle = .rounded
        assignButton.target = self
        assignButton.action = #selector(assignToTarget)
        assignButton.translatesAutoresizingMaskIntoConstraints = false
        let assignButtonW = assignButton.widthAnchor.constraint(equalToConstant: 270)
        assignButtonW.priority = .init(700)
        detailWidthConstraints.append(assignButtonW)
        assignButtonW.isActive = true
        root.addArrangedSubview(assignButton)

        removeButton.title = L10n.t("win.removeFromLibrary")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeFromLibrary)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        let removeButtonW = removeButton.widthAnchor.constraint(equalToConstant: 270)
        removeButtonW.priority = .init(700)
        detailWidthConstraints.append(removeButtonW)
        removeButtonW.isActive = true
        root.addArrangedSubview(removeButton)

        stopButton.title = L10n.t("win.stopAll")
        stopButton.target = self
        stopButton.action = #selector(stopAll)
        stopButton.bezelStyle = .rounded
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        let stopButtonW = stopButton.widthAnchor.constraint(equalToConstant: 270)
        stopButtonW.priority = .init(700)
        detailWidthConstraints.append(stopButtonW)
        stopButtonW.isActive = true
        root.addArrangedSubview(stopButton)

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        let pauseButtonW = pauseButton.widthAnchor.constraint(equalToConstant: 270)
        pauseButtonW.priority = .init(700)
        detailWidthConstraints.append(pauseButtonW)
        pauseButtonW.isActive = true
        root.addArrangedSubview(pauseButton)

        clearCurrentButton.title = L10n.t("win.clearCurrentDisplay")
        clearCurrentButton.bezelStyle = .rounded
        clearCurrentButton.target = self
        clearCurrentButton.action = #selector(clearCurrentDisplayWallpaper)
        clearCurrentButton.translatesAutoresizingMaskIntoConstraints = false
        let clearCurrentButtonW = clearCurrentButton.widthAnchor.constraint(equalToConstant: 270)
        clearCurrentButtonW.priority = .init(700)
        detailWidthConstraints.append(clearCurrentButtonW)
        clearCurrentButtonW.isActive = true
        root.addArrangedSubview(clearCurrentButton)

        clearAllButton.title = L10n.t("win.clearAllDisplays")
        clearAllButton.bezelStyle = .rounded
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllDisplaysWallpaper)
        clearAllButton.translatesAutoresizingMaskIntoConstraints = false
        let clearAllButtonW = clearAllButton.widthAnchor.constraint(equalToConstant: 270)
        clearAllButtonW.priority = .init(700)
        detailWidthConstraints.append(clearAllButtonW)
        clearAllButtonW.isActive = true
        root.addArrangedSubview(clearAllButton)

        // 操作按钮的最终顺序（按使用频率与破坏性递增排列）：
        // 设为该屏壁纸 → 暂停 → 停止全部 → 移到废纸篓
        //   → 移除当前显示器 → 移除所有显示器
        // 上面是逐块构建的，这里统一按目标顺序重排一次。
        let actionOrder: [NSView] = [
            assignButton,
            pauseButton,
            stopButton,
            removeButton,
            clearCurrentButton,
            clearAllButton,
        ]
        // 保留非操作按钮（标题、说明等）在原位，只重排操作按钮之间的相对次序
        var rebuilt: [NSView] = []
        for v in root.arrangedSubviews {
            if actionOrder.contains(where: { $0 === v }) { continue }
            rebuilt.append(v)
        }
        rebuilt.append(contentsOf: actionOrder)
        root.setViews(rebuilt, in: .leading)

        // 兼容性警告（有问题才显示）
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        warningLabel.textColor = .systemRed
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 2
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        let warnW = warningLabel.widthAnchor.constraint(equalToConstant: 270)
        warnW.priority = .init(700)
        detailWidthConstraints.append(warnW)
        warnW.isActive = true
        fixButton.bezelStyle = .rounded
        fixButton.controlSize = .small
        fixButton.target = self
        fixButton.action = #selector(fixIncompatibleVideo)
        let wRow = NSStackView(views: [warningLabel, fixButton])
        wRow.orientation = .vertical
        wRow.alignment = .leading
        wRow.spacing = 4
        wRow.isHidden = true
        warningRow = wRow
        root.addArrangedSubview(wRow)

        // 右栏内容（预览 + 名称 + 构图 + 操作）超过可视高度时按钮会被裁掉，
        // 必须能滚动。用最标准的 NSScrollView + NSClipView 写法。
        // 右栏内容超过可视高度时按钮会被裁掉，需要滚动。
        // 这里刻意不用 Auto Layout 排 doc：root 的子控件本身带固定宽度（270），
        // 与 doc↔contentView 的宽度约束互相冲突，会把内容压成 0 宽（实测整栏空白）。
        // 改用传统方式：scroll 走约束，doc 与 root 的 frame 在 layout 时手算。
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        // 跟随系统偏好：overlay 样式 + 自动隐藏 =
        // 滚动时浮现、停手 1 秒多后淡出，和 macOS 其它 App 一致。
        // 之前强制常显（.legacy + autohidesScrollers=false）又丑又挡内容。
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        doc.autoresizingMask = []
        // root 完全由 frame 驱动（syncDetailDocSize 负责），不参与 Auto Layout。
        // 之前这里设 true、而 root 创建处设 false，两者冲突，
        // 结果是内容被压成 2x2 的碎片（用户反馈的「控件显示异常」）。
        root.translatesAutoresizingMaskIntoConstraints = true
        root.autoresizingMask = []
        doc.addSubview(root)
        scroll.documentView = doc
        // 每次 doc 布局时重新量一次高度：
        // 不能只靠 refreshControls —— 启动时没有选中项会 early return，
        // 那条路走不到同步逻辑，右栏就一直是初始的压扁状态。
        doc.onLayout = { [weak self] in self?.syncDetailDocSize() }
        self.detailScroll = scroll
        self.detailDoc = doc
        self.detailRoot = root
        pane.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pane.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    /// 右栏专用：标签在上、控件在下（300px 宽塞不下左右并排）
    private func compactRow(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        control.translatesAutoresizingMaskIntoConstraints = false
        let ctrlW = control.widthAnchor.constraint(equalToConstant: 270)
        ctrlW.priority = .init(700)
        detailWidthConstraints.append(ctrlW)
        ctrlW.isActive = true
        let s = NSStackView(views: [l, control])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 3
        return s
    }

    private func compactSliderRow(_ label: String,
                                  _ slider: NSSlider,
                                  _ value: NSTextField) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor

        value.cell = VerticallyCenteredFieldCell()
        value.isEditable = true
        value.isSelectable = true
        value.alignment = .right
        // 22pt：与 NSSlider 同高，否则数值框会撑高整行、滑块看起来下沉
        styleRoundedField(value, height: 22, inset: 5)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.target = self
        value.action = #selector(numberFieldCommitted(_:))
        value.delegate = self
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 72).isActive = true

        slider.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [slider, value])
        row.orientation = .horizontal
        row.spacing = 6
        // 滑块与数值框沿中线对齐
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let rowW = row.widthAnchor.constraint(equalToConstant: 270)
        rowW.priority = .init(700)
        detailWidthConstraints.append(rowW)
        rowW.isActive = true

        let s = NSStackView(views: [l, row])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 3
        // 外层容器也要跟随宽度，否则 row 拉伸时外层不动
        s.translatesAutoresizingMaskIntoConstraints = false
        let sW = s.widthAnchor.constraint(equalToConstant: 270)
        sW.priority = .init(700)
        detailWidthConstraints.append(sW)
        sW.isActive = true
        return s
    }


    // MARK: 三栏联动

    /// 侧栏选中项变化：显示器 -> 设定 targetDisplayID；预设 -> 只选中（不自动加载，3B 决策）
    private func sidebarSelectionChanged(_ sel: SidebarSelection) {
        switch sel {
        case .allDisplays:
            displaySelection = .allDisplays
            targetDisplayID = ""
            refreshLibraryIfNeeded()
            refreshControls()
        case .display(let id):
            displaySelection = .display(id)
            targetDisplayID = id
            refreshLibraryIfNeeded()
            refreshControls()
        case .preset(let id):
            presetSelection = .preset(id)
            showPresetDetail(presetID: id)
        case .library(let cat):
            librarySelection = .library(cat)
            libraryFilter = cat
            // 切分类时先检查磁盘有没有变化（比如刚在访达里增删过文件）
            refreshLibraryIfNeeded()
            reloadLibrary()
            refreshControls()
        }
    }

    /// 选中预设时，右栏显示它的摘要与「加载」按钮；不自动应用
    /// 填充右栏的文件详情：文件名 / 分辨率 / 大小 / 分类 / 位置。
    /// 分辨率要从文件里读（图片走 ImageIO，视频走 AVAsset），
    /// 异步取，避免选中大文件时卡住主线程。
    private func updateFileInfo(for item: LibraryItem?) {
        guard let item else {
            fileInfoLabel.stringValue = ""
            return
        }
        let path = item.path
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let exists = fm.fileExists(atPath: path)

        // 文件名 / 分类 / 大小 / 位置 —— 这些都是同步就能拿到的
        let kind = item.kind == .video ? L10n.t("kind.video") : L10n.t("kind.image")
        let sizeText: String
        if !exists {
            sizeText = L10n.t("detail.fileMissing")
        } else if bytes >= 1024 * 1024 {
            sizeText = String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            sizeText = String(format: "%.0f KB", Double(bytes) / 1024)
        }

        // 位置：相对壁纸文件夹显示，超长时中间截断
        let folder = Settings.wallpaperFolder.standardizedFileURL.path
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        let loc: String
        if full.hasPrefix(folder + "/") {
            loc = String(full.dropFirst(folder.count + 1))
        } else {
            loc = full
        }

        func compose(_ resolution: String) -> String {
            let lines = [
                L10n.t("detail.fileName", (path as NSString).lastPathComponent),
                L10n.t("detail.resolution", resolution),
                L10n.t("detail.fileSize", sizeText),
                L10n.t("detail.fileKind", kind),
                L10n.t("detail.fileLocation", loc),
            ]
            return lines.joined(separator: "\n")
        }

        // 分辨率有缓存就直接出完整文字，避免「—」→ 真实值 的两段式闪烁
        if let cached = resolutionCache[path] {
            fileInfoLabel.stringValue = compose(cached)
            return
        }
        fileInfoLabel.stringValue = compose("—")

        guard exists else { return }

        // 异步取分辨率
        let path2 = path
        let isVideo = item.kind == .video
        DispatchQueue.global(qos: .userInitiated).async {
            var res = "—"
            if isVideo {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path2))
                let sem = DispatchSemaphore(value: 0)
                var size: CGSize = .zero
                Task {
                    if let track = try? await asset.loadTracks(withMediaType: .video).first,
                       let s = try? await track.load(.naturalSize),
                       let t = try? await track.load(.preferredTransform) {
                        size = s.applying(t)
                        size = CGSize(width: abs(size.width), height: abs(size.height))
                    }
                    sem.signal()
                }
                sem.wait()
                if size.width > 0 {
                    res = String(format: "%d×%d", Int(size.width), Int(size.height))
                }
            } else if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path2) as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int,
                      let h = props[kCGImagePropertyPixelHeight] as? Int {
                res = String(format: "%d×%d", w, h)
            }

            let finalRes = res
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 记下来：下次选中同一张就无需再算，也就不会闪
                self.resolutionCache[path2] = finalRes
                // 选中项可能已经变了，只有还是同一路径时才写入
                guard self.selectedItem?.path == path2 else { return }
                self.fileInfoLabel.stringValue = compose(finalRes)
            }
        }
    }

    private func showPresetDetail(presetID: String) {
        guard let p = state.presets.first(where: { $0.id == presetID }) else { return }
        sidebar.setInfo(title: p.name, subtitle: L10n.t("detail.presetSummary", p.displayCount))
        // 预设没有单一素材，取它里面第一张能用的来预览，
        // 让用户能看到「这套预设大概长什么样」。
        let cover = p.assignment.values.first { path in state.library.contains { $0.path == path } }
            ?? p.assignment.values.first
        previewPane.show(path: cover, fallbackText: L10n.t("preview.noImage"))
        updateFileInfo(for: nil)
        adjustControlsEnabled(false)
        assignButton.isEnabled = false
        removeButton.isEnabled = false
        // 加载按钮复用「设为该屏壁纸」位置不合适，改用状态提示 + 右键菜单加载
        loadPresetButton.isHidden = false
        refreshStopButton()
        refreshPresetButtons()
        updateStatus()
    }

    /// 按窗口宽度算网格列数（卡片 112 + 间距 8）
    /// 网格固定 4 列 × 5 行，窗口缩放时只调整缩略图尺寸。
    ///
    /// 之前行列都按空间算，窗口拉大就变成 8 列、分页消失 —— 每页数量飘忽不定，
    /// 找素材时反而没有稳定的位置记忆。现在锁定 4x5（一页 20 个），
    /// 界面变大时让卡片同步变大，视觉更舒展。
    /// 每页固定 25 个素材；行列组合随窗口比例自动变化。
    /// 
    /// 规则：先按可用宽度定列数（保证卡片宽度合适），
    /// 再用 ceil(25 / 列数) 反推行数 —— 这样无论窗口多宽多窄，一页永远是 25 个。
    /// 窗口高度不够时会溢出，网格自带滚动条可以往下拉（用户明确要求）。
    /// 固定 5 列，行数由素材数量决定（照 macOS 照片的网格）。
    ///
    /// 图片等高：卡片高度由「可用宽 ÷ 5」按图片比例算出，
    /// 这样每张缩略图高度一致，扫视时不会参差。
    /// 同步顶栏渐变 mask 的尺寸（CAGradientLayer 不会自动跟随）

    private func relayoutGridColumns() {
        guard window != nil else { return }

        // 列数由用户在顶栏控制，档位 3/5/7/9（与照片 App 一致）
        let cols = Settings.gridColumnCount

        // 先定网格形状，再调卡片尺寸 —— 顺序反了会被 setGrid 重建的 layout
        // 把 itemSize 覆盖回旧值（实测表现为「算的是 5 列，显示的是 4 列」）。
        let perPage = max(1, filteredLibrary().count)
        let rows = max(1, Int(ceil(Double(perPage) / Double(cols))))

        if cols != gridColumns || rows != gridRows {
            gridColumns = cols
            gridRows = rows
            thumbnailGrid.setGrid(columns: cols, rows: rows)
        }


        // 卡片宽 = 网格实际可用宽度均分。缩放只改缩略图大小，列数恒为 5。
        thumbnailGrid.applyCardSize(availableWidth: thumbnailGrid.availableGridWidth,
                                    columns: cols)
    }

    @objc private func searchChanged() {
        searchQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去抖 200ms：连续输入时只在停顿后重排一次网格。
        // 每次按键都全量过滤 + 重建网格与侧栏，309 个素材下能明显感到卡。
        searchDebounce?.invalidate()
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.reloadLibrary()
        }
    }

    /// 过滤图库：只匹配素材名（自定义名称 + 原始文件名）。
    /// 不匹配预设名 —— 搜索框在顶栏、语义是「找这张壁纸」，
    /// 若把预设名也算进来，输入内容与结果对不上，反而让人困惑。
    private func filteredLibrary() -> [LibraryItem] {
        // 先按侧栏选中的分类过滤，再按搜索词过滤
        var items = state.library
        if let cat = libraryFilter {
            items = items.filter { $0.category == cat }
        }
        guard !searchQuery.isEmpty else { return items }
        let q = searchQuery.lowercased()
        return items.filter { item in
            item.displayName.lowercased().contains(q)
                || item.name.lowercased().contains(q)
        }
    }

    /// 设置菜单。按功能分组成二级子菜单，避免一长串平铺项。
    /// 切换左栏分组顺序（六种排列）
    @objc private func setGroupOrder(_ sender: NSMenuItem) {
        guard let order = sender.representedObject as? String else { return }
        Settings.groupOrder = order.split(separator: ",").map(String.init)
        // 侧栏数据要重建（roots 是按当前设置算的）
        sidebar.reload(presets: state.presets,
                       screens: screens,
                       categories: wallpaperCategories(),
                       statuses: displayStatusMap().perDisplay,
                       aggregate: displayStatusMap().aggregate,
                       selection: displaySelection,
                       librarySelection: librarySelection,
                       presetSelection: presetSelection,
                       categoryCovers: categoryCoverMap())
    }

    @objc private func setSortKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Settings.sortKey = key
        resortLibraryInPlace()
    }

    @objc private func setSortOrder(_ sender: NSMenuItem) {
        guard let asc = sender.representedObject as? Bool else { return }
        Settings.sortAscending = asc
        resortLibraryInPlace()
    }

    /// 只按当前设置重排内存里的库，不重扫磁盘。
    ///
    /// 换排序键/方向时磁盘内容没变，重新遍历目录 + 逐个 stat 完全是浪费，
    /// 这也是点完菜单要等一下才刷新的原因。
    private func resortLibraryInPlace() {
        let t0 = Date()
        defer {
            if let fh = FileHandle(forWritingAtPath: "/tmp/wl-sort.log") {
                let d = String(format: "resort %.0f ms\n", Date().timeIntervalSince(t0) * 1000)
                fh.seekToEndOfFile(); fh.write(d.data(using: .utf8) ?? Data()); fh.closeFile()
            }
        }
        let byName = Settings.sortKey == "name"
        let asc = Settings.sortAscending
        StateStore.shared.update { st in
            let keyed: [(key: String, item: LibraryItem)] = st.library.map { item in
                let k = byName
                    ? (item.path as NSString).lastPathComponent.lowercased()
                    : Self.modifiedStamp(item.path)
                return (k, item)
            }
            st.library = keyed.sorted { asc ? ($0.key < $1.key) : ($0.key > $1.key) }
                .map { $0.item }
        }
        reloadLibrary()
    }

    /// 切换网格里文件名显示
    @objc private func toggleGridFileNames() {
        Settings.showGridFileNames.toggle()
        thumbnailGrid.setShowsFileNames(Settings.showGridFileNames)
        // 文件名显隐会改变卡片高度，需要重排
        relayoutGridColumns()
    }

    @objc private func showSettingsMenu() {
        let menu = NSMenu()

        // ── 播放 ──────────────────────────────────────────
        let playback = NSMenuItem(title: L10n.t("menu.playback"), action: nil, keyEquivalent: "")
        let playbackSub = NSMenu()

        let fs = NSMenuItem(title: L10n.t("menu.pauseOnFullscreen"),
                            action: #selector(toggleFullscreenPause),
                            keyEquivalent: "")
        fs.target = self
        fs.state = Settings.pauseOnFullscreen ? .on : .off
        playbackSub.addItem(fs)

        let bat = NSMenuItem(title: L10n.t("menu.pauseOnBattery"),
                             action: #selector(togglePauseOnBattery),
                             keyEquivalent: "")
        bat.target = self
        bat.state = Settings.pauseOnBattery ? .on : .off
        playbackSub.addItem(bat)

        playback.submenu = playbackSub
        menu.addItem(playback)

        // ── 壁纸库 ────────────────────────────────────────
        let library = NSMenuItem(title: L10n.t("setting.library"), action: nil, keyEquivalent: "")
        let librarySub = NSMenu()

        // 网格文件名显隐
        let showNames = NSMenuItem(title: L10n.t("setting.showFileNames"),
                                   action: #selector(toggleGridFileNames),
                                   keyEquivalent: "")
        showNames.target = self
        showNames.state = Settings.showGridFileNames ? .on : .off
        librarySub.addItem(showNames)

        librarySub.addItem(.separator())

        // ── 拖拽应用壁纸（开关） ──
        let dragApply = NSMenuItem(title: L10n.t("setting.dragToApply"),
                                   action: #selector(toggleDragToApply),
                                   keyEquivalent: "")
        dragApply.target = self
        dragApply.state = Settings.dragToApplyEnabled ? .on : .off
        librarySub.addItem(dragApply)

        librarySub.addItem(.separator())

        // ── 左栏分组顺序 ──
        let orderMenuItem = NSMenuItem(title: L10n.t("setting.groupOrder"),
                                       action: nil, keyEquivalent: "")
        let orderMenuSub = NSMenu()
        let currentOrder = Settings.groupOrder.joined(separator: ",")
        let orderChoices: [(String, String)] = [
            ("display,library,preset", "setting.order.dlp"),
            ("display,preset,library", "setting.order.dpl"),
            ("library,display,preset", "setting.order.ldp"),
            ("library,preset,display", "setting.order.lpd"),
            ("preset,display,library", "setting.order.pdl"),
            ("preset,library,display", "setting.order.pld"),
        ]
        for (value, labelKey) in orderChoices {
            let it = NSMenuItem(title: L10n.t(labelKey),
                                action: #selector(setGroupOrder(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = value
            it.state = currentOrder == value ? .on : .off
            orderMenuSub.addItem(it)
        }
        orderMenuItem.submenu = orderMenuSub
        librarySub.addItem(orderMenuItem)

        librarySub.addItem(.separator())

        // ── 排序依据：文件名 / 修改时间 ──
        let sortByItem = NSMenuItem(title: L10n.t("setting.sortBy"), action: nil, keyEquivalent: "")
        let sortBySub = NSMenu()
        for (key, labelKey) in [("name", "setting.sortByName"), ("date", "setting.sortByDate")] {
            let it = NSMenuItem(title: L10n.t(labelKey),
                                action: #selector(setSortKey(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = Settings.sortKey == key ? .on : .off
            sortBySub.addItem(it)
        }
        sortByItem.submenu = sortBySub
        librarySub.addItem(sortByItem)

        // ── 排序方向：升序 / 降序 ──
        let orderItem = NSMenuItem(title: L10n.t("setting.sortOrder"), action: nil, keyEquivalent: "")
        let orderSub = NSMenu()
        for (asc, labelKey) in [(true, "setting.sortAsc"), (false, "setting.sortDesc")] {
            let it = NSMenuItem(title: L10n.t(labelKey),
                                action: #selector(setSortOrder(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = asc
            it.state = Settings.sortAscending == asc ? .on : .off
            orderSub.addItem(it)
        }
        orderItem.submenu = orderSub
        librarySub.addItem(orderItem)

        librarySub.addItem(.separator())
        let cur = NSMenuItem(title: L10n.t("setting.currentFolder", Settings.wallpaperFolder.path),
                             action: nil, keyEquivalent: "")
        cur.isEnabled = false
        librarySub.addItem(cur)
        let change = NSMenuItem(title: L10n.t("setting.changeFolder"),
                                action: #selector(changeWallpaperFolder),
                                keyEquivalent: "")
        change.target = self
        librarySub.addItem(change)

        library.submenu = librarySub
        menu.addItem(library)

        // ── 语言 ──────────────────────────────────────────
        let langItem = NSMenuItem(title: L10n.t("setting.language"), action: nil, keyEquivalent: "")
        let langSub = NSMenu()
        for lang in L10n.Language.allCases {
            let title: String
            switch lang {
            case .system:  title = L10n.t("setting.language.system")
            case .chinese: title = L10n.t("setting.language.chinese")
            case .english: title = L10n.t("setting.language.english")
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(changeLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = (L10n.language == lang) ? .on : .off
            langSub.addItem(item)
        }
        langItem.submenu = langSub
        menu.addItem(langItem)

        // ── 启动 ──────────────────────────────────────────
        let auto = NSMenuItem(title: L10n.t("menu.launchAtLogin"),
                              action: #selector(toggleAutoStart),
                              keyEquivalent: "")
        auto.target = self
        auto.state = isAutoStartEnabled() ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        let reveal = NSMenuItem(title: L10n.t("menu.openAppFolder"),
                                action: #selector(revealAppInFinder),
                                keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: settingsButton.bounds.height + 4),
                   in: settingsButton)
    }

    /// 弹出输入框让用户自填每页数量。
    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = L10n.Language(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: "uiLanguage")

        // 语言是全局静态判定，已经构建好的控件不会自动换文案，
        // 所以重建整窗是最直接可靠的方式。
        let alert = NSAlert()
        alert.messageText = L10n.t("setting.language.changed")
        alert.informativeText = L10n.t("setting.language.restartHint")
        alert.addButton(withTitle: L10n.t("common.save"))
        alert.runModal()

        // 记录当前语言，下次启动生效（本次已构建的界面文案不追改）
        _ = lang
    }

    /// 更改壁纸库路径：选完立刻重新扫描，把新目录里的壁纸读进来。
    @objc private func changeWallpaperFolder() {
        let current = Settings.wallpaperFolder
        guard let picked = pickFolder(startingAt: current) else { return }
        Settings.wallpaperFolder = picked
        Settings.hasChosenWallpaperFolder = true
        try? FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)

        // 换了目录，之前的分类筛选可能已不存在
        libraryFilter = nil
        scanWallpaperFolder()
        reloadLibrary()
        flashStatus(L10n.t("folder.changed"))
    }

    @objc private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// 预设右键菜单
    private func makePresetMenu(id: String, view: NSView) -> NSMenu? {
        guard let p = state.presets.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()

        let load = NSMenuItem(title: L10n.t("preset.load"),
                              action: #selector(loadPresetFromMenu(_:)),
                              keyEquivalent: "")
        load.target = self
        load.representedObject = p.id
        menu.addItem(load)

        let rename = NSMenuItem(title: L10n.t("preset.rename"),
                                action: #selector(renamePresetFromMenu(_:)),
                                keyEquivalent: "")
        rename.target = self
        rename.representedObject = p.id
        menu.addItem(rename)

        menu.addItem(.separator())

        let del = NSMenuItem(title: L10n.t("preset.delete"),
                             action: #selector(deletePresetFromMenu(_:)),
                             keyEquivalent: "")
        del.target = self
        del.representedObject = p.id
        menu.addItem(del)
        return menu
    }

    /// 重命名预设：右键菜单入口
    @objc private func renamePresetFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = state.presets.first(where: { $0.id == id }) else { return }
        guard let input = promptForPresetName(defaultValue: p.name) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != p.name else { return }

        StateStore.shared.update { st in
            guard let i = st.presets.firstIndex(where: { $0.id == id }) else { return }
            st.presets[i].name = trimmed
        }
        reloadPresets()
        // 保持选中，方便连续操作
        presetSelection = .preset(id)
        showPresetDetail(presetID: id)
    }

    @objc private func loadPresetFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = state.presets.first(where: { $0.id == id }) else { return }
        applyPreset(p)
    }

    @objc private func deletePresetFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = state.presets.first(where: { $0.id == id }) else { return }
        StateStore.shared.update { st in st.presets.removeAll { $0.id == id } }
        reloadPresets()
        flashStatus(L10n.t("preset.deleted", p.name))
    }

    // MARK: 自适应尺寸


    /// 右栏内部的分组横线。与三栏竖线同色同观感。
    private func separator(width: CGFloat = 555) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(srgbRed: 0.34, green: 0.35, blue: 0.37, alpha: 1).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let w = v.widthAnchor.constraint(equalToConstant: width)
        detailWidthConstraints.append(w)
        w.isActive = true
        return v
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
        value.cell = VerticallyCenteredFieldCell()
        value.isEditable = true
        value.isSelectable = true
        value.alignment = .right
        styleRoundedField(value)
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
        // libraryPopup 是三栏改版前的控件，已不在视图层级里。
        // 之前每次重载都给它重建 300+ 项菜单，纯属浪费（实测是卡顿主因）。
        // 保留属性以免牵动其它引用，但不再刷新内容。
        // 同步网格（用过滤后的结果；搜索时只显示命中的素材）
        let used = Set(state.assignment.values)
        let visible = filteredLibrary()
        thumbnailGrid.reload(visible,
                             inUse: used,
                             selectedPath: selectedItem?.path)
        updateEmptyState(visibleCount: visible.count)
        updateLibraryHeader(visibleCount: visible.count)
        refreshHeaderButtons()
        relayoutGridColumns()
        // 侧栏也要跟着刷新（预设可能增删、屏幕可能变化）
        let st = displayStatusMap()
        sidebar.reload(presets: state.presets,
                       screens: screens,
                       categories: wallpaperCategories(),
                       statuses: st.perDisplay,
                       aggregate: st.aggregate,
                       selection: displaySelection,
                       librarySelection: librarySelection,
                       presetSelection: presetSelection,
                       categoryCovers: categoryCoverMap())
        refreshControls()
    }

    /// 根据当前场景更新空状态卡片的文案。
    ///
    /// 三种「空」的成因完全不同，笼统说「没有素材」会让用户困惑：
    /// - 库为空：新用户，需要完整引导
    /// - 搜索无结果：是他自己筛出来的，只需说明没匹配到
    /// - 当前分类为空：库里有素材但不在这个文件夹，该提示去别的分类找
    /// 更新顶部浮栏的标题：当前分类 + 素材数。
    /// 这个位置原本是空的（标题被挪到 logo 右边），现在有了渐变模糊层，
    /// 它终于能回到照片 App 里的位置。
    private func updateLibraryHeader(visibleCount: Int) {
        let cat = libraryFilter ?? ""
        libraryHeaderTitle?.stringValue = cat.isEmpty ? L10n.t("nav.libraryAll") : cat
        libraryHeaderSubtitle?.stringValue = L10n.t("header.count", visibleCount)
        syncLibraryHeaderMask()
    }

    private func updateEmptyState(visibleCount: Int) {
        guard let card = libraryEmptyLabel else { return }
        card.isHidden = visibleCount > 0
        guard visibleCount == 0 else { return }

        let searching = !searchField.stringValue.isEmpty
        let categoryEmpty = !state.library.isEmpty

        if searching {
            emptyTitleLabel?.stringValue = L10n.t("empty.noMatch")
            emptyStepsLabel?.stringValue = ""
            emptyStepsLabel?.isHidden = true
            emptyActionButton?.isHidden = true
        } else if categoryEmpty {
            // 库里有素材、只是当前分类空 —— 引导用户回「全部」去找，
            // 而不是打开文件夹（那会让人以为要去别处搬东西）
            emptyTitleLabel?.stringValue = L10n.t("empty.emptyCategory")
            emptyStepsLabel?.stringValue = L10n.t("empty.emptyCategoryHint")
            emptyStepsLabel?.isHidden = false
            emptyActionButton?.isHidden = true
        } else {
            emptyTitleLabel?.stringValue = L10n.t("empty.title")
            emptyStepsLabel?.stringValue = L10n.t("empty.steps")
            emptyStepsLabel?.isHidden = false
            emptyActionButton?.isHidden = false
        }
    }

    /// 用户点了网格卡片：只更新选择，不应用壁纸
    private func selectFromGrid(path: String) {
        StateStore.shared.update { st in
            st.lastSelectedItem = path
        }
        thumbnailGrid.select(path: path, notify: false)
        refreshControls()
    }
    // MARK: 重命名

    /// 名称框提交：写入 alias，然后刷新下拉框与网格
    @objc private func nameFieldCommitted(_ sender: NSTextField) {
        guard let item = selectedItem else { return }
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        StateStore.shared.update { st in
            guard let i = st.library.firstIndex(where: { $0.path == item.path }) else { return }
            // 与文件名完全相同视为「清除别名」，避免冗余存储
            st.library[i].alias = (trimmed.isEmpty || trimmed == st.library[i].name) ? nil : trimmed
        }
        reloadLibrary()
    }

    /// 恢复当前选中素材的文件名（清除别名）
    @objc private func resetNameForSelection() {
        guard let item = selectedItem else { return }
        StateStore.shared.update { st in
            guard let i = st.library.firstIndex(where: { $0.path == item.path }) else { return }
            st.library[i].alias = nil
        }
        // 名称框同步清空（此时显示的是文件名占位）
        reloadLibrary()
    }

    /// 卡片右键菜单
    /// 右键左栏的分类文件夹。
    private func makeCategoryMenu(category: String?, view: NSView) -> NSMenu? {
        guard let cat = category else { return nil }
        let menu = NSMenu()

        let reveal = NSMenuItem(title: L10n.t("category.revealInFinder"),
                                action: #selector(revealCategoryInFinder(_:)),
                                keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = cat
        menu.addItem(reveal)

        menu.addItem(.separator())

        let trash = NSMenuItem(title: L10n.t("category.moveToTrash"),
                               action: #selector(trashCategory(_:)),
                               keyEquivalent: "")
        trash.target = self
        trash.representedObject = cat
        menu.addItem(trash)

        return menu
    }

    /// 在访达中显示该分类文件夹
    @objc private func revealCategoryInFinder(_ sender: NSMenuItem) {
        guard let cat = sender.representedObject as? String else { return }
        let dir = Settings.wallpaperFolder.appendingPathComponent(cat, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// 把整个分类文件夹移到废纸篓（可恢复），并把它从库里清掉
    @objc private func trashCategory(_ sender: NSMenuItem) {
        guard let cat = sender.representedObject as? String else { return }
        let dir = Settings.wallpaperFolder.appendingPathComponent(cat, isDirectory: true)

        // 二次确认：整个文件夹都会进废纸篓，不是小操作
        let alert = NSAlert()
        alert.messageText = L10n.t("category.trashTitle")
        alert.informativeText = L10n.t("category.trashBody", cat)
        alert.addButton(withTitle: L10n.t("common.delete"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            do {
                try fm.trashItem(at: dir, resultingItemURL: nil)
            } catch {
                flashStatus(L10n.t("category.trashFailed", cat))
                return
            }
        }

        // 若当前正看着这个分类，回到「全部」
        if case .library(let curr) = librarySelection, curr == cat {
            librarySelection = .library(nil)
            libraryFilter = nil
        }
        // 该分类下的素材从库里移除（文件已随文件夹进废纸篓）
        StateStore.shared.update { st in
            st.library.removeAll { $0.category == cat }
        }
        cachedCategories = nil          // 目录结构变了
        scanWallpaperFolder()
        reloadLibrary()
        flashStatus(L10n.t("category.trashed", cat))
    }

    /// 中栏空白处的右键菜单：库级操作。
    private func makeBlankMenu(view: NSView) -> NSMenu? {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: L10n.t("library.refresh"),
                                 action: #selector(refreshLibraryNow),
                                 keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let add = NSMenuItem(title: L10n.t("win.addFiles"),
                             action: #selector(addFiles),
                             keyEquivalent: "")
        add.target = self
        menu.addItem(add)

        menu.addItem(.separator())

        let reveal = NSMenuItem(title: L10n.t("library.revealFolder"),
                                action: #selector(revealWallpaperFolder),
                                keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        return menu
    }

    /// 立即重扫壁纸文件夹。
    /// 用于在访达里增删文件、或从废纸篓复原后让 App 立刻看到变化。
    @objc private func refreshLibraryNow() {
        scanWallpaperFolder()
        reloadLibrary()
        flashStatus(L10n.t("library.refreshed"))
    }

    /// 在访达中打开当前壁纸文件夹
    @objc private func revealWallpaperFolder() {
        NSWorkspace.shared.open(Settings.wallpaperFolder)
    }

    private func makeCardMenu(path: String, view: NSView) -> NSMenu? {
        guard let item = state.library.first(where: { $0.path == path }) else { return nil }
        let menu = NSMenu()

        // 改名走访达：UI 不再提供入口（用文件名即可）


        let assign = NSMenuItem(title: L10n.t("win.setWallpaper"),
                                action: #selector(assignFromCard(_:)),
                                keyEquivalent: "")
        assign.target = self
        assign.representedObject = path
        menu.addItem(assign)

        let reveal = NSMenuItem(title: L10n.t("menu.reveal"),
                                action: #selector(revealInFinder(_:)),
                                keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = path
        menu.addItem(reveal)

        menu.addItem(.separator())

        let remove = NSMenuItem(title: L10n.t("win.removeFromLibrary"),
                                action: #selector(removeFromCard(_:)),
                                keyEquivalent: "")
        remove.target = self
        remove.representedObject = path
        menu.addItem(remove)

        return menu
    }

    @objc private func beginRenameFromCard(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let idx = state.library.firstIndex(where: { $0.path == path }) else { return }
        StateStore.shared.update { st in st.lastSelectedItem = path }
        refreshControls()
    }

    @objc private func resetNameFromCard(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        StateStore.shared.update { st in
            guard let i = st.library.firstIndex(where: { $0.path == path }) else { return }
            st.library[i].alias = nil
        }
        reloadLibrary()
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func assignFromCard(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        StateStore.shared.update { st in
            for s in self.targetScreens {
                st.assignment[screenID(s)] = path
            }
            st.stoppedAssignment = nil
        }
        WallpaperManager.shared.applyAll()
        reloadLibrary()
    }

    @objc private func removeFromCard(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let idx = state.library.firstIndex(where: { $0.path == path }) else { return }
        StateStore.shared.update { st in st.lastSelectedItem = path }
        removeFromLibrary()
    }

    private var targetScreens: [NSScreen] {
        targetDisplayID.isEmpty ? screens : screens.filter { screenID($0) == targetDisplayID }
    }

    private var selectedItem: LibraryItem? {
        // 以前靠 libraryPopup 的选中索引；那个控件已不在界面里，
        // 改读持久化的 lastSelectedItem，语义更直接。
        guard let path = state.lastSelectedItem else { return nil }
        return state.library.first { $0.path == path }
    }

    /// 把 doc 与 root 的 frame 按实际内容高度设置。
    /// NSScrollView 只在 documentView.frame 高于可视区时才产生可滚区域。
    private func syncDetailDocSize() {
        guard let scroll = detailScroll, let doc = detailDoc, let root = detailRoot else { return }

        // 宽度来源要稳：contentView.bounds 在布局早期可能极小（甚至 1~2pt），
        // 那时若直接用，root 会被压扁，而内部控件都锁了 270pt 固定宽，
        // 结果是整栏控件缩成 2x2 的碎片（实测出现过）。
        // 这里取「pane 实际宽度」作为基准，并对过小值直接放弃本次同步，
        // 等下一次布局回调再算。
        let paneWidth = detailScroll?.superview?.bounds.width ?? 0
        let w = max(scroll.contentView.bounds.width, paneWidth)
        guard w > 120 else { return }   // 明显异常时不动，等下一轮

        // 子元素宽度跟随栏宽（左右各 16 内边距）。
        // 下限不能设成 200：右栏窄到 220 时 220-32=188 会被抬到 200，
        // 元素反而比可用宽度还宽，右边就顶出面板了。
        let contentW = max(80, w - 32)
        if abs((detailWidthConstraints.first?.constant ?? 0) - contentW) > 0.5 {
            for c in detailWidthConstraints { c.constant = contentW }
            // 多行标签的换行宽度要跟着栏宽走，否则换行点永远停在旧的 270
            fileInfoLabel.preferredMaxLayoutWidth = contentW
        }

        root.frame = NSRect(x: 0, y: 0, width: w, height: root.frame.height)
        root.layoutSubtreeIfNeeded()
        let h = max(root.fittingSize.height, scroll.contentView.bounds.height)
        root.frame = NSRect(x: 0, y: 0, width: w, height: h)
        doc.frame = NSRect(x: 0, y: 0, width: w, height: h)
        doc.setFrameSize(NSSize(width: w, height: h))

    }

    /// 标题：当前分类名 + 素材数。
    /// 现在显示在左侧栏面板顶部（红绿灯下方），不再占顶栏。
    private func updateHeaderTitle() {
        let catName: String
        if let cat = libraryFilter {
            catName = cat
        } else {
            catName = L10n.t("nav.libraryAll")
        }
        let count = filteredLibrary().count
        // 标题由顶栏承载（顶栏现在通栏模糊，标题浮在它上面）。
        // 位置在左栏右缘，也就是中栏起点 —— 与照片 App 一致。
        topTitle?.stringValue = catName
        topSubtitle?.stringValue = L10n.t("header.count", count)
        // 中栏自己那份标题已经移除（它会让标题重复出现两次）
        libraryHeaderTitle?.stringValue = catName
        libraryHeaderSubtitle?.stringValue = L10n.t("header.count", count)
    }

    /// 刷新左栏底部的信息框：当前作用范围、分辨率、那块屏正在用的壁纸。
    ///
    /// 它是「显示器状态」，不是「素材详情」，所以与是否选中素材无关。
    private func refreshSidebarInfo() {
        let scopeName = targetDisplayID.isEmpty
            ? L10n.t("common.allDisplaysCount", screens.count)
            : (screens.first { screenID($0) == targetDisplayID }.map { screenTitle($0) }
               ?? L10n.t("common.unknownDisplay"))

        guard let s = targetScreens.first ?? NSScreen.screens.first else {
            sidebar.setInfo(title: scopeName, subtitle: "")
            return
        }
        let scale = s.backingScaleFactor
        let w = Int(s.frame.width * scale)
        let h = Int(s.frame.height * scale)
        let title = "\(scopeName)  \(w)×\(h)"

        if let using = state.assignment[screenID(s)] {
            let usingName = state.library.first { $0.path == using }?.displayName
                ?? (using as NSString).lastPathComponent
            sidebar.setInfo(title: title, subtitle: L10n.t("detail.using", usingName))
        } else {
            sidebar.setInfo(title: title, subtitle: L10n.t("detail.notUsing"))
        }
    }

    private func refreshControls() {
        updateHeaderTitle()
        loadPresetButton.isHidden = true
        loadPresetButton.isEnabled = false
        guard let item = selectedItem else {
            scopeLabel.stringValue = L10n.t("win.scope.none")

            // 信息框显示的是「当前显示器」的状态，与有没有选中素材无关
            refreshSidebarInfo()
            paneTitle.stringValue = ""
            previewPane.show(path: nil, fallbackText: L10n.t("preview.noSelection"))
            updateFileInfo(for: nil)
            adjustControlsEnabled(false)
            refreshStopButton()
            refreshPresetButtons()
            updateStatus()
            syncDetailDocSize()
            return
        }
        // 名称框跟随选中素材；正在编辑时不要覆盖用户输入

        // 没有别名时「恢复文件名」无意义，置灰
        refreshStopButton()
        refreshPresetButtons()
        adjustControlsEnabled(true)
        let scopeName = targetDisplayID.isEmpty
            ? L10n.t("common.allDisplaysCount", screens.count)
            : (screens.first { screenID($0) == targetDisplayID }.map { screenTitle($0) } ?? L10n.t("common.unknownDisplay"))
        scopeLabel.stringValue = L10n.t("win.scope", scopeName, item.displayName)

        // 左栏信息框：显示器状态（与选中哪一个素材无关）
        refreshSidebarInfo()
        // 预览图上方的文件名标题
        paneTitle.stringValue = item.displayName
        // 右栏大图预览：此前只更新了标题与副标题，从未调用 previewPane.show，
        // 所以选中素材时预览区一直空白（用户反馈的 bug）。
        previewPane.show(path: item.path, fallbackText: L10n.t("preview.noImage"))
        updateFileInfo(for: item)
        loadPresetButton.isHidden = true
        loadPresetButton.isEnabled = false

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
        updateFramingSummary(adj: adj)
        muteCheck.state = state.muted ? .on : .off
        // 速度控件只对视频出现：图片没有「快放」这个概念，
        // 显示一个永远无效的控件只会让人困惑。
        let isVideo = (item.kind == .video)
        rateRow?.isHidden = !isVideo
        if isVideo {
            // 值与某个预设档位吻合就高亮它；自定义值则取消选中，
            // 否则分段控件会假装选中 1× 而实际跑在 1.37×，自相矛盾。
            if let idx = Adjustment.rateOptions.firstIndex(where: {
                abs($0 - adj.playbackRate) < 0.001
            }) {
                rateControl.selectedSegment = idx
            } else {
                rateControl.selectedSegment = -1
            }
            // 输入框跟随显示当前值（两位小数足够表达 0.25–2.0）。
            // 用户正在编辑时不要覆盖 —— 否则刚敲到一半就被重置。
            let editing = (rateField.currentEditor() != nil)
            let s = String(format: "%.2f", adj.playbackRate)
            if !editing, rateField.stringValue != s {
                rateField.stringValue = s
            }
        }
        applyButtEnabled(item)
        updateValueLabels()
        updateStatus()
        checkCompatibility(item)
        syncDetailDocSize()
        syncLibraryHeaderMask()
        syncTopBarMask()
    }

    /// 更新构图摘要。
    ///
    /// 用自然语言而不是复述三个数字：「放大 150% · 右移 12」比「1.5 / 0.12 / 0」
    /// 直观得多，也更容易让人意识到这些值是**这块屏专属**的。
    /// 全默认时写「默认构图」，让「没调过」和「调过」一眼可分 ——
    /// 后者才是这个功能的价值所在。
    private func updateFramingSummary(adj: Adjustment) {
        let isDefault = abs(adj.zoom - 1.0) < 0.001
            && abs(adj.offsetX) < 0.001
            && abs(adj.offsetY) < 0.001
        if isDefault {
            framingSummary.stringValue = L10n.t("framing.default")
            framingSummary.textColor = .tertiaryLabelColor
            return
        }
        var parts: [String] = []
        if abs(adj.zoom - 1.0) >= 0.001 {
            parts.append(L10n.t("framing.zoom", Int((adj.zoom * 100).rounded())))
        }
        if abs(adj.offsetX) >= 0.001 {
            // 正值向右；数值是相对画面宽度的比例，换算成百分数更好读
            let pct = Int((adj.offsetX * 50).rounded())
            parts.append(pct >= 0 ? L10n.t("framing.right", pct)
                                  : L10n.t("framing.left", -pct))
        }
        if abs(adj.offsetY) >= 0.001 {
            let pct = Int((adj.offsetY * 50).rounded())
            parts.append(pct >= 0 ? L10n.t("framing.up", pct)
                                  : L10n.t("framing.down", -pct))
        }
        framingSummary.stringValue = L10n.t("framing.summary", parts.joined(separator: " · "))
        framingSummary.textColor = .secondaryLabelColor
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
        rateControl.isEnabled = on
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

    /// 计算每块显示器的壁纸状态（供侧栏小圆点显示）。
    ///
    /// 绿 = 正在显示；橙黄 = 已暂停（手动暂停 / 全屏遮挡 / 电池供电）；
    /// 白 = 未应用壁纸。
    private func displayStatusMap() -> (perDisplay: [String: DisplayStatus],
                                        aggregate: DisplayStatus) {
        let manager = WallpaperManager.shared
        var map: [String: DisplayStatus] = [:]
        for s in screens {
            let id = screenID(s)
            let hasWallpaper = state.assignment[id] != nil
            if !hasWallpaper {
                map[id] = .empty
            } else if manager.isPaused || FullscreenMonitor.shared.coveredScreens.contains(id) {
                map[id] = .paused
            } else {
                map[id] = .active
            }
        }

        // 聚合：有任一屏在用就是绿；否则有壁纸（全暂停）是橙黄；否则白
        let values = Array(map.values)
        let aggregate: DisplayStatus
        if values.contains(.active) {
            aggregate = .active
        } else if values.contains(.paused) {
            aggregate = .paused
        } else {
            aggregate = .empty
        }
        return (map, aggregate)
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
            // 高亮对应缩略图（notify: false 避免回调成环）
            thumbnailGrid.select(path: item.path, notify: false)
        }
        refreshControls()
    }

    /// 拖拽放入的处理：加入后给一行明确反馈。
    ///
    /// 复制在后台进行，所以结果在回调里拿到 —— 期间导入浮标一直转着，
    /// 用户不会面对一个毫无反应的窗口。
    private func handleDrop(_ paths: [String]) {
        let total = paths.count
        addPaths(paths) { [weak self] result in
            guard let self else { return }
            self.endImport()
            if result.added == 0 {
                // 拖的全是本文件夹里已有的图 —— 说清楚原因，
                // 比笼统一句「已存在」有用得多。
                if result.allAlreadyHere {
                    self.showToast(L10n.t("drop.alreadyInFolder"), success: false)
                } else {
                    self.showToast(L10n.t("drop.nothingAdded"), success: false)
                }
            } else if result.added < total {
                self.showToast(L10n.t("drop.addedPartial", result.added, total - result.added))
            } else {
                self.showToast(L10n.t("drop.added", result.added))
            }
        }
    }

    /// 在状态栏临时显示一条提示，几秒后恢复常规状态
    private func flashStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .controlAccentColor
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(restoreStatus),
                                               object: nil)
        perform(#selector(restoreStatus), with: nil, afterDelay: 3.0)
    }

    @objc private func restoreStatus() {
        statusLabel.textColor = .secondaryLabelColor
        updateStatus()
    }

    /// 首次启动时确认壁纸文件夹位置。
    /// 默认 ~/Pictures/WallLocus，用户可以直接用默认值，也可以另选目录。
    private func ensureWallpaperFolder() {
        guard !Settings.hasChosenWallpaperFolder else {
            // 已确认过：确保目录存在即可
            try? FileManager.default.createDirectory(at: Settings.wallpaperFolder,
                                                     withIntermediateDirectories: true)
            return
        }

        let folder = Settings.wallpaperFolder
        let alert = NSAlert()
        alert.messageText = L10n.t("folder.firstRunTitle")
        alert.informativeText = L10n.t("folder.firstRunBody", folder.path)
        alert.addButton(withTitle: L10n.t("folder.useDefault"))
        alert.addButton(withTitle: L10n.t("folder.chooseOther"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Settings.wallpaperFolder = folder
        case .alertSecondButtonReturn:
            if let picked = pickFolder(startingAt: folder) {
                Settings.wallpaperFolder = picked
            }
        default:
            // 取消：仍然标记为已确认，避免每次启动都弹；用默认值
            break
        }

        Settings.hasChosenWallpaperFolder = true
        try? FileManager.default.createDirectory(at: Settings.wallpaperFolder,
                                                 withIntermediateDirectories: true)
    }

    /// 弹目录选择面板，返回用户选中的目录
    private func pickFolder(startingAt: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = startingAt
        panel.prompt = L10n.t("folder.choosePrompt")
        panel.message = L10n.t("folder.chooseBody")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 把一个外部文件复制进壁纸文件夹，返回新路径。
    /// 已经在文件夹内的文件原样返回，不重复复制。
    /// 把外部文件复制进壁纸文件夹，返回落地路径。
    /// 纯文件操作、不碰 UI 与状态 —— 会在后台线程调用，切勿在此访问状态或界面。
    /// - Parameters:
    ///   - path: 源文件绝对路径
    ///   - category: 落地的分类子目录（空串 = 壁纸文件夹根）
    /// 一次导入的整体结果，交给调用方决定怎么提示
    struct AddResult {
        /// 实际新增到库里的个数
        let added: Int
        /// 是否所有文件都因为「本来就在目标文件夹里」而被跳过。
        /// 用来区分「拖回了同一个文件夹」和「拖的全是已在库中的外部文件」。
        let allAlreadyHere: Bool
    }

    /// 单个文件的导入结果
    private struct ImportOutcome {
        /// 落地后的绝对路径
        let path: String
        /// 是否因为「本来就在目标目录里」而跳过了复制。
        /// 这种跳过不是失败，但也不该算成新增 —— 用户拖的就是这个文件夹里的图。
        let alreadyInDestination: Bool
        /// 是否因同名而改了文件名（-2、-3 …）
        let renamed: Bool
    }

    private func importIntoWallpaperFolder(_ path: String, category: String? = nil) -> ImportOutcome {
        let fm = FileManager.default
        let folder = Settings.wallpaperFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // 拖入时若正看着某个分类，就把文件放进那个子文件夹 ——
        // 否则文件进了根目录，在当前分类里根本看不到（用户以为没加成功）。
        // 分类由调用方在主线程取好再传进来：这里可能跑在后台队列上。
        let destDir: URL
        let cat = category ?? ""
        if !cat.isEmpty {
            let sub = folder.appendingPathComponent(cat, isDirectory: true)
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            destDir = sub
        } else {
            destDir = folder
        }

        let src = URL(fileURLWithPath: path).standardizedFileURL

        // 只有「源文件已经在目标目录里」才算无需复制。
        //
        // 这里必须判断**目标目录**，不能判断「是否在壁纸库内」：
        // 用户在 25.12.3 里选图、拖进 test，是一个合法的「复制到另一分类」，
        // 源文件恰好在库内并不改变这个意图。按「在库内」提前返回，
        // 结果就是文件没进 test、入库时又被当成重复而跳过 —— 看起来完全没反应。
        if src.deletingLastPathComponent().path == destDir.standardizedFileURL.path {
            // 已经在目标目录里，无需复制。
            // 这正好是「用户在访达打开着当前分类，又把里面的图拖回来」的场景 ——
            // 调用方会据此给出专门提示，而不是笼统地说「已存在」。
            return ImportOutcome(path: path, alreadyInDestination: true, renamed: false)
        }

        var dest = destDir.appendingPathComponent(src.lastPathComponent)
        // 同名冲突时加序号，绝不覆盖用户已有文件
        var renamed = false
        if fm.fileExists(atPath: dest.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            var i = 2
            repeat {
                let name = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
                dest = destDir.appendingPathComponent(name)
                i += 1
            } while fm.fileExists(atPath: dest.path) && i < 1000
            renamed = true
        }

        do {
            try fm.copyItem(at: src, to: dest)
            return ImportOutcome(path: dest.path,
                                 alreadyInDestination: false,
                                 renamed: renamed)
        } catch {
            // 复制失败就退回原路径，不阻断添加
            return ImportOutcome(path: path, alreadyInDestination: false, renamed: false)
        }
    }

    /// 扫描壁纸文件夹，把里面的素材（含子文件夹）收进素材库。
    ///
    /// 子文件夹名即分类：根目录下的文件 category 为空，
    /// 子文件夹 a/ 下的文件 category 为 "a"。只扫一层子目录，
    /// 不做无限递归（更深的层级对壁纸库没有意义，也容易误收系统文件）。
    /// 文件夹「指纹」：目录自身与其直接子项的修改时间。
    /// 用于判断自上次扫描以来磁盘是否真的变了 —— 切分类、切显示器这类
    /// 高频操作不能每次都全量扫盘并重建库。
    private func folderFingerprint() -> String {
        let fm = FileManager.default
        let folder = Settings.wallpaperFolder
        var parts: [String] = []

        func stamp(_ url: URL) -> String {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let m = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return String(format: "%020.6f", m)
        }

        parts.append(stamp(folder))
        if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for n in names.sorted() where !n.hasPrefix(".") {
                let full = folder.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full.path, isDirectory: &isDir) else { continue }
                parts.append(n + stamp(full))
            }
        }
        return parts.joined(separator: "|")
    }

    /// 只在磁盘内容真的变了时才重扫并刷新图库。
    /// 返回是否发生了重扫。
    @discardableResult
    private func refreshLibraryIfNeeded() -> Bool {
        let fp = folderFingerprint()
        guard fp != lastFolderFingerprint else { return false }
        lastFolderFingerprint = fp
        scanWallpaperFolder()
        reloadLibrary()
        return true
    }

    private func scanWallpaperFolder() {
        let fm = FileManager.default
        let folder = Settings.wallpaperFolder
        guard fm.fileExists(atPath: folder.path) else { return }

        var found: [(path: String, category: String)] = []

        func collect(in dir: URL, category: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names {
                if n.hasPrefix(".") { continue }          // 跳过 .DS_Store 等
                let full = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    // 只往下走一层，避免深度递归
                    if category.isEmpty { collect(in: full, category: n) }
                    continue
                }
                if MediaTypes.isSupported(full.path) {
                    found.append((full.path, category))
                }
            }
        }
        collect(in: folder, category: "")

        guard !found.isEmpty || !state.library.isEmpty else { return }

        cachedCategories = nil   // 目录结构可能变了
        StateStore.shared.update { st in
            // 以文件夹为准重建库：保留已有条目的别名，新增的补上，
            // 文件已不存在的移除。
            var byPath = [String: LibraryItem]()
            for it in st.library { byPath[it.path] = it }

            var rebuilt: [LibraryItem] = []
            for f in found {
                var item = byPath[f.path] ?? LibraryItem(path: f.path,
                                                         kind: MediaKind.detect(f.path))
                item.category = f.category
                rebuilt.append(item)
            }
            // 按设置排序：文件名 / 修改时间 × 升序 / 降序。
            // 先算出每项的排序键再排 —— 直接在比较器里取文件属性，
            // N 个文件会触发约 N·logN 次 stat 系统调用（309 项约 2400 次），
            // 实测点一下排序要卡一秒多。
            let byName = Settings.sortKey == "name"
            let asc = Settings.sortAscending
            let keyed: [(key: String, item: LibraryItem)] = rebuilt.map { item in
                let k = byName
                    ? (item.path as NSString).lastPathComponent.lowercased()
                    : Self.modifiedStamp(item.path)
                return (k, item)
            }
            let sorted = keyed.sorted { asc ? ($0.key < $1.key) : ($0.key > $1.key) }
            st.library = sorted.map { $0.item }
        }

        // 壁纸文件没了，对应的分配也该清掉
        StateStore.shared.update { st in
            let alive = Set(st.library.map { $0.path })
            for (id, p) in st.assignment where !alive.contains(p) {
                st.assignment.removeValue(forKey: id)
            }
        }
    }

    /// 文件的修改时间戳（用于「按时间排序」）。
    /// 取不到时返回固定值，避免排序不稳定。
    private static func modifiedStamp(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = attrs?[.modificationDate] as? Date
        // 用固定宽度的秒数保证字典序 == 时间序
        return String(format: "%020.6f", date?.timeIntervalSince1970 ?? 0)
    }

    /// 壁纸文件夹下的所有分类（子文件夹名），按名称排序
    /// 把某个素材应用到指定显示器（displayID 为空串表示全部）。
    ///
    /// 拖拽两条路径（左栏显示器行、屏幕覆盖层）都走这里，
    /// 保证行为与状态栏提示完全一致。
    func applyWallpaper(path: String, displayID: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            flashStatus(L10n.t("detail.fileMissing"))
            return
        }
        guard state.library.contains(where: { $0.path == path }) else { return }

        StateStore.shared.update { st in
            if displayID.isEmpty {
                for s in self.screens {
                    st.assignment[screenID(s)] = path
                }
            } else {
                st.assignment[displayID] = path
            }
            // 用户手动改了配置，旧的「停止前快照」不再有意义
            st.stoppedAssignment = nil
        }
        WallpaperManager.shared.applyAll()

        // 状态栏确认
        let name = (path as NSString).lastPathComponent
        if displayID.isEmpty {
            flashStatus(L10n.t("wallpaper.appliedAll", name))
        } else if let s = screens.first(where: { screenID($0) == displayID }) {
            flashStatus(L10n.t("wallpaper.appliedOne", name, s.localizedName))
        } else {
            flashStatus(L10n.t("wallpaper.appliedAll", name))
        }
        refreshControls()
    }

    /// 每个分类的封面：取该分类里的第一张图片素材。
    /// 侧栏用它渲染圆角方形缩略图，替代原来的文件夹图标。
    private func categoryCoverMap() -> [String: String] {
        var map: [String: String] = [:]
        var allCover: String?
        for item in state.library {
            // 「全部」用整个库的第一张
            if allCover == nil { allCover = item.path }
            let cat = item.category
            guard !cat.isEmpty else { continue }
            if map[cat] == nil { map[cat] = item.path }
        }
        return map
    }

    private func wallpaperCategories() -> [String] {
        // 缓存结果：分类只在扫描文件夹时才会变，
        // 而 reloadLibrary 会被搜索 / 选中 / 状态刷新频繁调用，
        // 每次都扫一遍目录是纯浪费。
        if let cached = cachedCategories { return cached }
        let fm = FileManager.default
        let folder = Settings.wallpaperFolder
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var dirs: [String] = []
        for n in names where !n.hasPrefix(".") {
            var isDir: ObjCBool = false
            let full = folder.appendingPathComponent(n)
            if fm.fileExists(atPath: full.path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(n)
            }
        }
        let result = dirs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cachedCategories = result
        return result
    }

    /// 新建一个分类（= 壁纸文件夹下的子文件夹）
    @objc private func newCategory() {
        let alert = NSAlert()
        alert.messageText = L10n.t("category.newTitle")
        alert.informativeText = L10n.t("category.newBody")
        alert.addButton(withTitle: L10n.t("common.save"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.t("category.namePlaceholder")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // 拒绝路径分隔符，避免建出意料之外的层级
        guard !name.contains("/") && !name.contains(":") else {
            flashStatus(L10n.t("category.invalidName"))
            return
        }

        let dir = Settings.wallpaperFolder.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scanWallpaperFolder()
            reloadLibrary()
            flashStatus(L10n.t("category.created", name))
        } catch {
            flashStatus(L10n.t("category.createFailed"))
        }
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
        let paths = panel.urls.map { $0.path }
        let total = paths.count
        addPaths(paths) { [weak self] result in
            guard let self else { return }
            self.endImport()
            if result.added == 0 {
                if result.allAlreadyHere {
                    self.showToast(L10n.t("drop.alreadyInFolder"), success: false)
                } else {
                    self.showToast(L10n.t("drop.nothingAdded"), success: false)
                }
            } else if result.added < total {
                self.showToast(L10n.t("drop.addedPartial", result.added, total - result.added))
            } else {
                self.showToast(L10n.t("drop.added", result.added))
            }
        }
    }

    /// 把一组路径加入素材库（面板选择与拖拽共用）。
    /// 返回实际新增的数量，供调用方做提示。
    @discardableResult
    /// 把外部文件加入壁纸库。
    ///
    /// 复制在后台队列执行 —— 大视频是几百 MB，同步复制会把整个窗口冻住，
    /// 用户既看不到进度也不知道是否还活着。这里先在主线程把需要的值取好
    /// （目标分类、支持的类型），再整批复制的活儿交给后台，完成后回主线程入库。
    ///
    /// - Parameter paths: 源文件绝对路径
    /// - Parameter completion: 主线程回调，参数为新增数量
    func addPaths(_ paths: [String], completion: ((AddResult) -> Void)? = nil) {
        guard !paths.isEmpty else { completion?(AddResult(added: 0, allAlreadyHere: false)); return }

        // 只接受本应用能处理的类型，避免把随便什么文件塞进库里
        let supported = paths.filter { MediaTypes.isSupported($0) }
        guard !supported.isEmpty else { completion?(AddResult(added: 0, allAlreadyHere: false)); return }

        // 分类必须在主线程取：后台线程不能读 libraryFilter。
        let category = libraryFilter ?? ""

        beginImport(total: supported.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 统一收进壁纸文件夹：外部文件会被复制进来，
            // 这样素材库的位置稳定，不依赖用户原始文件是否被移动或删除。
            var outcomes: [ImportOutcome] = []
            outcomes.reserveCapacity(supported.count)
            for p in supported {
                outcomes.append(self.importIntoWallpaperFolder(p, category: category))
            }
            let usable = outcomes.map { $0.path }

            DispatchQueue.main.async {
                // 复制已经落盘，先记下扫描前的库，用于事后判断哪些是新的。
                let before = Set(self.state.library.map { $0.path })

                // 直接以磁盘为准重建库：新复制进来的文件本来就在文件夹里，
                // 重扫一步到位，还能顺带修正它们所属的分类。
                //
                // 不能「先按 usable 逐条 append、再重扫」：
                // 重扫是**以文件夹为准重建**，会把上一行刚 append 的条目
                // 按实际磁盘位置重新归类，两者叠加容易把计数算错。
                // 更关键的是，复制期间若发生过自动刷新（切回 App 会触发），
                // 文件可能已经被扫进库了 —— 这时再按路径判重就会误报「已存在」，
                // 而用户明明刚把文件拖进了另一个分类。
                self.scanWallpaperFolder()
                self.reloadLibrary()

                // 以「目标路径现在是否在库中」为准统计新增，
                // 而不是拿复制前后的临时列表相减。
                let after = Set(self.state.library.map { $0.path })
                let added = usable.filter { after.contains($0) && !before.contains($0) }.count

                // 全部都是「本来就在这个文件夹里」—— 这是用户在访达打开着当前分类、
                // 又把里面的图拖回来的场景。要说清楚原因，不能笼统报「已存在」。
                let allAlreadyHere = outcomes.allSatisfy { $0.alreadyInDestination }
                // 选中新加入的素材，方便用户接着决定要不要用它
                if added > 0, self.state.library.contains(where: { $0.path == usable[0] }) {
                    StateStore.shared.update { $0.lastSelectedItem = usable[0] }
                }
                // 只刷新界面，不重铺壁纸 —— assignment 没变，重铺纯属多余。
                self.refreshControls()
                completion?(AddResult(added: added, allAlreadyHere: allAlreadyHere))
            }
        }
    }

    // MARK: 中栏顶部渐变模糊浮栏

    /// 构建中栏顶部的渐变模糊条。
    ///
    /// 结构（从下到上）：
    /// 1. NSVisualEffectView 提供**真实高斯模糊**（blur 一个子视图，不裁文字）
    /// 2. 模糊层带 CAGradientLayer mask，上实下透 —— 内容是「渐渐模糊」，
    ///    而不是「渐渐变透明」
    /// 3. 标题独立浮在模糊层之上，**完全不参与 mask**
    ///
    /// 两个必须分开的理由：
    /// - mask 加在 blur.layer 上会把同层的文字一起裁掉（第一版的 bug，标题半透明）
    /// - 只做 alpha 渐变只是个透明的矩形，没有模糊，观感很廉价
    private func makeLibraryHeader() -> NSVisualEffectView {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // 容器本身**不负责模糊**：它只是承载模糊层与文字的透明底板。
        // 若直接在容器上开模糊，渐变 mask 会把文字一起吃掉。
        container.material = .underWindowBackground
        container.blendingMode = .withinWindow
        container.state = .active
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true

        // 真正做模糊的层：铺满容器、带渐变 mask
        let blurLayer = NSVisualEffectView()
        blurLayer.translatesAutoresizingMaskIntoConstraints = false
        blurLayer.material = .underWindowBackground
        // 用 .withinWindow：采样的是**窗口内、本层之下**的内容 ——
        // 也就是中栏那些缩略图，模糊后从浮栏下方透出来。
        // .behindWindow 采的是桌面，而窗口已有 baseBlur 底板，
        // 再模糊一次等于模糊的模糊，浮栏几乎看不出存在（实测）。
        blurLayer.blendingMode = .withinWindow
        blurLayer.state = .active
        blurLayer.appearance = NSAppearance(named: .darkAqua)
        blurLayer.wantsLayer = true
        container.addSubview(blurLayer)

        let mask = CAGradientLayer()
        // 末尾用 alpha 0 的白而非 clear：clear 会被当成「黑 + 0 alpha」，
        // 插值途中拖出一层灰，底部边界能看见一条线。
        mask.colors = [
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.7).cgColor,
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        mask.locations = [0.0, 0.35, 0.68, 1.0]
        mask.startPoint = CGPoint(x: 0.5, y: 1.0)
        mask.endPoint = CGPoint(x: 0.5, y: 0.0)
        blurLayer.layer?.mask = mask
        libraryHeaderMask = mask

        // 一层很淡的压暗，让浮栏在亮壁纸上也有体积感
        let tint = PassthroughLayerView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tint)

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(subtitle)
        libraryHeaderTitle = title
        libraryHeaderSubtitle = subtitle

        NSLayoutConstraint.activate([
            blurLayer.topAnchor.constraint(equalTo: container.topAnchor),
            blurLayer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blurLayer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blurLayer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tint.topAnchor.constraint(equalTo: container.topAnchor),
            tint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])

        return container
    }

    /// 浮栏文字的兜底阴影：模糊背景的明暗不可控，
    /// 一层很淡的深色阴影能让浅色文字在任何底上都站得住。
    static func headerTextShadow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowBlurRadius = 3
        s.shadowOffset = NSSize(width: 0, height: -1)
        return s
    }

    /// 同步顶栏渐变遮罩的尺寸。
    ///
    /// CAGradientLayer 不跟随父视图 —— 不同步的话它停在 0×0，
    /// 整条顶栏的模糊与压暗都会被裁成没有，看起来就只剩一层薄薄的底色。
    /// 中栏浮栏有同名方法，顶栏这份之前漏了（实际 bug）。
    private func syncTopBarMask() {
        guard let bar = topBarBlur, let mask = topBarMask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bar.bounds
        CATransaction.commit()
    }

    /// 同步浮栏渐变的尺寸。
    /// CAGradientLayer 不会随父视图自动变宽，必须在 layout 之后手动同步 ——
    /// 不更新的话遮罩停在初始的 0 尺寸，整条浮栏会完全透明。
    private func syncLibraryHeaderMask() {
        guard let blur = libraryHeaderBlur, let mask = libraryHeaderMask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = blur.bounds
        CATransaction.commit()
    }
    // MARK: 空状态引导

    /// 图库为空时的引导卡片。
    ///
    /// 新用户打开看到一个空网格和三栏面板，不知道素材从哪来。
    /// 这里用最小成本把主流程讲清楚：壁纸来自一个文件夹、拖进来、拖到屏幕上。
    /// 选择空状态卡片而非多步弹窗：无持久化状态、随时可回到这个状态、实现简单。
    private func makeEmptyStateCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 图标
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.stack",
                             accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        // 标题
        let title = NSTextField(labelWithString: L10n.t("empty.title"))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        // 三步说明
        let steps = NSTextField(labelWithString: L10n.t("empty.steps"))
        steps.font = NSFont.systemFont(ofSize: 12)
        steps.textColor = .tertiaryLabelColor
        steps.alignment = .center
        steps.maximumNumberOfLines = 0
        steps.lineBreakMode = .byWordWrapping
        steps.preferredMaxLayoutWidth = 300
        steps.translatesAutoresizingMaskIntoConstraints = false

        // 打开壁纸文件夹按钮
        let openButton = NSButton(title: L10n.t("empty.openFolder"),
                                  target: self,
                                  action: #selector(revealWallpaperFolder))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(14, after: icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(steps)
        stack.setCustomSpacing(14, after: steps)
        stack.addArrangedSubview(openButton)

        emptyTitleLabel = title
        emptyStepsLabel = steps
        emptyActionButton = openButton

        card.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        return card
    }

    // MARK: 导入进度

    /// 构建导入浮标：一枚圆角胶囊 + 转圈 + 文案。
    /// 用视觉分层而非边框，避免在中栏淡色玻璃上显得突兀。
    private func makeImportBanner() -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 9
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        box.isHidden = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L10n.t("import.inProgress", 0))
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        // 成功后的对勾：与转圈占同一格、同一尺寸，靠 isHidden 互换。
        // 转圈停下就整体消失会留下一条空白，看着像「少了什么」；
        // 换成对勾既补上这个空位，也让「完成」这件事有个明确的视觉落点。
        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                              accessibilityDescription: nil)
        check.contentTintColor = NSColor.systemGreen
        check.imageScaling = .scaleProportionallyUpOrDown
        check.isHidden = true
        check.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(spinner)
        box.addSubview(check)
        box.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),

            // 与 spinner 完全重合，两者永不并存
            check.leadingAnchor.constraint(equalTo: spinner.leadingAnchor),
            check.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            check.heightAnchor.constraint(equalToConstant: 12),

            // 文案锚在 spinner 上（它始终占位，只是隐藏），
            // 这样转圈换对勾时文字不会横向跳动。
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            box.heightAnchor.constraint(equalToConstant: 26),
        ])

        importLabel = label
        importIndicator = spinner
        importCheck = check
        return box
    }

    /// 进入「正在导入」状态：显示浮层、开始加载指示。
    /// 用户此刻应立即看到反馈 —— 大文件复制要好几秒，没有提示就像卡死。
    private func beginImport(total: Int) {
        importInFlight += 1
        // 导入开始要取消可能还在显示的结果浮标，
        // 否则「已添加 3 个」会和转圈同时挂在那儿，自相矛盾。
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(hideToast),
                                               object: nil)
        toastCount = 0
        importLabel?.stringValue = L10n.t("import.inProgress", total)
        importCheck?.isHidden = true
        importIndicator?.isHidden = false
        importIndicator?.startAnimation(nil)
        importBanner?.isHidden = false
    }

    /// 在导入浮标上显示一条结果，几秒后消失。
    /// 底栏已被移除（statusLabel 永远隐藏），所以结果提示复用同一个浮标位，
    /// 把转圈换成对勾、把文案换成结果 —— 位置不变，用户的视线不用移动。
    /// 在浮标上显示结果。
    /// - Parameter success: 真的有素材入库才显示绿色对勾；
    ///   一个都没加进来时用中性图标，否则「未添加」配个绿勾自相矛盾。
    private func showToast(_ message: String, success: Bool = true) {
        toastCount += 1
        importIndicator?.stopAnimation(nil)
        importIndicator?.isHidden = true
        importCheck?.image = NSImage(
            systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            accessibilityDescription: nil)
        importCheck?.contentTintColor = success ? .systemGreen : .systemOrange
        importCheck?.isHidden = false
        importLabel?.stringValue = message
        importBanner?.isHidden = false
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(hideToast),
                                               object: nil)
        perform(#selector(hideToast), with: nil, afterDelay: 2.6)
    }

    @objc private func hideToast() {
        // 还有别的批次在导入就不要关，交给最后那批收尾
        guard importInFlight == 0 else { return }
        importBanner?.isHidden = true
    }

    /// 退出「正在导入」状态。用计数而非布尔，
    /// 是为了处理「导入过程中又拖进来一批」——先结束的那批不该把指示器关掉。
    /// 注意这里**不隐藏浮标**：紧随其后的结果提示要复用同一个位置，
    /// 先隐藏会让浮标闪一下再出现。
    private func endImport() {
        importInFlight = max(0, importInFlight - 1)
        guard importInFlight == 0 else { return }
        importIndicator?.stopAnimation(nil)
    }

    @objc private func assignToTarget() {
        guard let item = selectedItem else { return }
        StateStore.shared.update { st in
            for s in self.targetScreens {
                st.assignment[screenID(s)] = item.path
            }
            // 用户已经手动决定了新配置，旧的「停止前快照」不再有意义
            st.stoppedAssignment = nil
        }
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    @objc private func removeFromLibrary() {
        guard let item = selectedItem else { return }

        // 真正把文件移到废纸篓（可恢复）。
        // 之前只从库里删条目、文件留在文件夹，下次扫描又冒出来，
        // 「移到废纸篓」看起来没生效。
        let fm = FileManager.default
        if fm.fileExists(atPath: item.path) {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: item.path),
                                 resultingItemURL: nil)
            } catch {
                flashStatus(L10n.t("error.trashFailed",
                                   (item.path as NSString).lastPathComponent))
                return
            }
        }

        // 素材已移除，缩略图缓存一并丢掉
        ThumbnailStore.shared.remove(for: item.path)

        // 先算出删除后该选中谁：优先同位置的下一项，没有就选前一项。
        // 不处理的话 lastSelectedItem 会指向已删除的路径（实测会悬空），
        // 下次启动 reloadLibrary 找不到它，下拉框就停在第 0 项。
        let removedIdx = state.library.firstIndex(where: { $0.path == item.path }) ?? 0
        var nextSelection: String?
        if state.library.count > 1 {
            let fallbackIdx = min(removedIdx, state.library.count - 2)
            let remaining = state.library.filter { $0.path != item.path }
            if fallbackIdx < remaining.count {
                nextSelection = remaining[fallbackIdx].path
            }
        }

        StateStore.shared.update { st in
            st.library.removeAll { $0.path == item.path }
            for (display, path) in st.assignment where path == item.path {
                st.assignment[display] = nil
            }
            for display in st.adjustments.keys {
                st.adjustments[display]?.removeValue(forKey: item.path)
            }
            // 快照里若还引用着这个素材，还原时就得跳过它；
            // 那样还原出来的配置会缺一块，不如直接作废整份快照。
            if st.stoppedAssignment?.values.contains(item.path) == true {
                st.stoppedAssignment = nil
            }
            st.lastSelectedItem = nextSelection
        }
        reloadLibrary()
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    /// 只清除当前所选显示器上的壁纸，其它屏不动。
    @objc private func clearCurrentDisplayWallpaper() {
        // 目标是侧栏选中的那块屏；选的是「全部显示器」时退化为清除全部
        let targets: [String]
        if targetDisplayID.isEmpty {
            targets = Array(state.assignment.keys)
        } else {
            targets = [targetDisplayID]
        }
        guard targets.contains(where: { state.assignment[$0] != nil }) else {
            flashStatus(L10n.t("status.noWallpaperOnDisplay"))
            return
        }
        StateStore.shared.update { st in
            for id in targets { st.assignment.removeValue(forKey: id) }
            st.stoppedAssignment = nil
        }
        WallpaperManager.shared.applyAll()
        WallpaperManager.shared.purgeCaches()
        refreshControls()
        flashStatus(L10n.t("status.clearedDisplay", targets.count))
    }

    /// 清除所有显示器上的壁纸。
    ///
    /// 比 stopButton 更「硬」：不做快照、按钮也不会变成「还原壁纸」，
    /// 清掉就没了。因此加了二次确认，避免误点把三块屏的配置一次清空。
    @objc private func clearAllDisplaysWallpaper() {
        guard !state.assignment.isEmpty else {
            flashStatus(L10n.t("status.nothingToStop"))
            return
        }
        let count = state.assignment.count

        let alert = NSAlert()
        alert.messageText = L10n.t("confirm.clearAllTitle", count)
        alert.informativeText = L10n.t("confirm.clearAllBody")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("confirm.clearAllConfirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        StateStore.shared.update { st in
            st.assignment.removeAll()
            st.stoppedAssignment = nil
        }
        WallpaperManager.shared.applyAll()
        WallpaperManager.shared.purgeCaches()
        refreshControls()
        flashStatus(L10n.t("status.clearedAll", count))
    }

    /// 停止全部 / 还原壁纸 —— 同一个按钮，按当前状态切换行为。
    /// 
    /// 停止是破坏性的（三块屏要重新一个个配），所以先把分配快照存进 state，
    /// 按钮随即变成「还原壁纸」，点一下就能回到停掉之前的完整配置。
    @objc private func stopAll() {
        if state.canRestoreStopped && state.assignment.isEmpty {
            restoreStopped()
            return
        }

        let snapshot = state.assignment
        guard !snapshot.isEmpty else {
            // 本来就没有壁纸，没有可停也没有可还原的
            flashStatus(L10n.t("status.nothingToStop"))
            return
        }

        StateStore.shared.update { st in
            st.stoppedAssignment = snapshot
            st.assignment.removeAll()
        }
        WallpaperManager.shared.applyAll()
        // 显式清掉已不在屏幕上的位图。此前这里漏了清理，
        // 导致「停止全部壁纸」后内存纹丝不动（实测 308 MB 不变）。
        WallpaperManager.shared.purgeCaches()
        refreshControls()
        flashStatus(L10n.t("status.stoppedAll", snapshot.count))
    }

    // MARK: 预设

    /// 重建预设下拉：名称 + 「N 块屏」摘要。
    private func reloadPresets(select id: String? = nil) {
        presetPopup.removeAllItems()
        if state.presets.isEmpty {
            presetPopup.addItem(withTitle: L10n.t("preset.empty"))
            presetPopup.isEnabled = false
        } else {
            presetPopup.isEnabled = true
            for p in state.presets {
                presetPopup.addItem(withTitle: "\(p.name)  ·  \(p.displayCount)")
            }
            if let id = id,
               let idx = state.presets.firstIndex(where: { $0.id == id }) {
                presetPopup.selectItem(at: idx)
            }
        }
        refreshPresetButtons()
        // 三栏改版后预设显示在左侧导航里；这里不同步侧栏的话，
        // 保存成功的预设只会进数据，界面上看不到（实测就是这个 bug）。
        let st = displayStatusMap()
        sidebar.reload(presets: state.presets,
                       screens: screens,
                       categories: wallpaperCategories(),
                       statuses: st.perDisplay,
                       aggregate: st.aggregate,
                       selection: displaySelection,
                       librarySelection: librarySelection,
                       presetSelection: presetSelection,
                       categoryCovers: categoryCoverMap())
    }

    private func refreshPresetButtons() {
        let hasPreset = !state.presets.isEmpty && presetPopup.indexOfSelectedItem >= 0
        loadPresetButton.isEnabled = hasPreset
        deletePresetButton.isEnabled = hasPreset
        // 没有任何屏在用时存预设没有意义
        savePresetButton.isEnabled = !state.assignment.isEmpty
    }

    @objc private func presetSelectionChanged() {
        refreshPresetButtons()
    }

    /// 把当前的「屏 × 壁纸」配置存成预设，连同这些组合的构图调整量。
    @objc private func savePreset() {
        guard !state.assignment.isEmpty else {
            flashStatus(L10n.t("preset.nothingToSave"))
            return
        }

        let suggested = L10n.t("preset.defaultName", state.presets.count + 1)
        guard let name = promptForPresetName(defaultValue: suggested) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 只取预设实际用到的那些调整量，避免把无关数据也塞进去
        var relevant: [String: [String: Adjustment]] = [:]
        for (display, path) in state.assignment {
            if let adj = state.adjustments[display]?[path] {
                relevant[display, default: [:]][path] = adj
            }
        }

        let preset = WallpaperPreset(name: trimmed,
                                     assignment: state.assignment,
                                     adjustments: relevant)
        StateStore.shared.update { st in
            // 同名视为覆盖，省得列表里堆一堆重名项
            st.presets.removeAll { $0.name == trimmed }
            st.presets.append(preset)
        }
        // 保存后直接把新预设选中，用户能立刻在侧栏看到它并查看详情
        presetSelection = .preset(preset.id)
        reloadPresets(select: preset.id)
        showPresetDetail(presetID: preset.id)
        flashStatus(L10n.t("preset.saved", trimmed, preset.displayCount))
    }

    /// 面板里「加载」按钮：按侧栏当前选中的预设应用。
    @objc private func loadSelectedPresetFromButton() {
        guard let sel = presetSelection,
              case .preset(let id) = sel,
              let p = state.presets.first(where: { $0.id == id }) else { return }
        applyPreset(p)
    }

    @objc private func loadSelectedPreset() {
        let idx = presetPopup.indexOfSelectedItem
        guard idx >= 0, idx < state.presets.count else { return }
        applyPreset(state.presets[idx])
    }

    /// 应用预设。显示器 UUID 对不上（换过屏、拔过线）或素材已删除的条目跳过，
    /// 并把跳过的数量告诉用户，而不是整份失败。
    private func applyPreset(_ preset: WallpaperPreset) {
        let alive = Set(screens.map { screenID($0) })
        var applied = 0
        var skipped = 0

        StateStore.shared.update { st in
            for (display, path) in preset.assignment {
                guard alive.contains(display),
                      st.library.contains(where: { $0.path == path }) else {
                    skipped += 1
                    continue
                }
                st.assignment[display] = path
                if let adj = preset.adjustments[display]?[path] {
                    st.setAdjustment(adj, display: display, item: path)
                }
                applied += 1
            }
            // 预设是用户明确的选择，旧的「停止前快照」不再有意义
            st.stoppedAssignment = nil
        }

        // 应用后把选择同步到预设里第一块屏用的素材，方便继续微调
        if let firstPath = preset.assignment.values.first(where: { p in
            state.library.contains { $0.path == p }
        }), let idx = state.library.firstIndex(where: { $0.path == firstPath }) {
            StateStore.shared.update { $0.lastSelectedItem = firstPath }
        }

        WallpaperManager.shared.applyAll()
        reloadLibrary()
        refreshControls()

        if applied == 0 {
            flashStatus(L10n.t("preset.loadFailed"))
        } else if skipped > 0 {
            flashStatus(L10n.t("preset.loadedPartial", preset.name, applied, skipped))
        } else {
            flashStatus(L10n.t("preset.loaded", preset.name, applied))
        }
    }

    @objc private func deleteSelectedPreset() {
        let idx = presetPopup.indexOfSelectedItem
        guard idx >= 0, idx < state.presets.count else { return }
        let target = state.presets[idx]

        let alert = NSAlert()
        alert.messageText = L10n.t("preset.deleteConfirmTitle", target.name)
        alert.informativeText = L10n.t("preset.deleteConfirmBody")
        alert.addButton(withTitle: L10n.t("common.delete"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        StateStore.shared.update { st in
            st.presets.removeAll { $0.id == target.id }
        }
        reloadPresets()
        flashStatus(L10n.t("preset.deleted", target.name))
    }

    /// 弹一个输入框要名字。取消返回 nil。
    private func promptForPresetName(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.t("preset.namePromptTitle")
        alert.informativeText = L10n.t("preset.namePromptBody")
        alert.addButton(withTitle: L10n.t("common.save"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// 按钮标题/可用性随状态变化：
    ///   有壁纸            -> 「停止全部壁纸」可用
    ///   没壁纸但有快照    -> 「还原壁纸」可用
    ///   没壁纸也没快照    -> 置灰
    private func refreshStopButton() {
        if state.assignment.isEmpty && state.canRestoreStopped {
            stopButton.title = L10n.t("win.restoreAll")
            stopButton.isEnabled = true
        } else {
            stopButton.title = L10n.t("win.stopAll")
            stopButton.isEnabled = !state.assignment.isEmpty
        }
    }

    /// 把上次停止前的分配找回来。
    @objc private func restoreStopped() {
        guard let snapshot = state.stoppedAssignment, !snapshot.isEmpty else { return }

        // 只还原那些「现在还能对上」的显示器；换过屏/拔过线的条目直接跳过，
        // 免得把壁纸塞到一个已经不存在的 display UUID 上。
        let alive = Set(screens.map { screenID($0) })
        var restored = 0
        StateStore.shared.update { st in
            for (id, path) in snapshot where alive.contains(id) {
                // 素材可能已经从库里删掉了，跳过
                guard st.library.contains(where: { $0.path == path }) else { continue }
                st.assignment[id] = path
                restored += 1
            }
            st.stoppedAssignment = nil
        }
        WallpaperManager.shared.applyAll()
        refreshControls()

        if restored == 0 {
            flashStatus(L10n.t("status.restoreFailed"))
        } else if restored < snapshot.count {
            flashStatus(L10n.t("status.restoredPartial", restored, snapshot.count - restored))
        } else {
            flashStatus(L10n.t("status.restored", restored))
        }
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
        }
        WallpaperManager.shared.applyAll()
        refreshControls()
    }

    // MARK: 新手引导

    /// 打开「新手引导」面板。
    ///
    /// 空库时中栏本身会显示引导卡片，但那只服务「什么都没加」的状态。
    /// 已经用了一阵的人想回看这三个步骤，需要一个不依赖库状态的入口 ——
    /// 所以做成独立面板，从应用菜单随时打开。
    @objc private func showQuickGuide() {
        let alert = NSAlert()
        alert.messageText = L10n.t("guide.title")
        alert.informativeText = L10n.t("guide.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("guide.openFolder"))
        alert.addButton(withTitle: L10n.t("common.close"))

        if alert.runModal() == .alertFirstButtonReturn {
            revealWallpaperFolder()
        }
    }

    /// 折叠/展开右栏。
    ///
    /// 浏览大量壁纸时右栏一直占着 300pt，把它收起来中栏能多显示一列。
    /// 折叠状态持久化 —— 用户既然选了更大的浏览区，重启后不该又变回去。
    @objc private func toggleDetailPane() {
        detailCollapsed.toggle()
        Settings.detailPaneCollapsed = detailCollapsed
        applyDetailCollapse(animated: false)
    }

    /// 把折叠状态应用到布局上
    private func applyDetailCollapse(animated: Bool) {
        if detailCollapsed {
            // 关键：把右栏整体推出窗口右缘，而不是只把宽度设成 0。
            // 只设宽度的话，中栏的 trailing 仍绑在 right.leading 上、
            // 而 right.trailing 固定在 container 右缘，中栏反而被挤压，
            // 结果按钮被推到窗口外、网格也没变宽（实测如此）。
            rightWidthConstraint.constant = rightWidth
            rightTrailingConstraint.constant = rightWidth + 16
        } else {
            rightWidthConstraint.constant = rightWidth
            rightTrailingConstraint.constant = -8
        }
        detailPaneView?.isHidden = detailCollapsed
        // 折叠时不显示分隔拖拽条，避免在 0 宽位置上误拖
        rightHandleView?.isHidden = detailCollapsed

        // 中栏右缘：展开时贴右栏（留 8pt 缝）；折叠时贴窗口右缘。
        //
        // 不切换的话，折叠后中栏的右缘仍绑在已被推出窗口的右栏上，
        // 整条边界跟着跑到窗口外 —— 滚动条被裁掉、右侧也没有边距，
        // 看起来像「内容一直顶到窗口外」。
        if detailCollapsed {
            middleTrailingConstraint?.isActive = false
            middleTrailingCollapsed?.isActive = true
        } else {
            middleTrailingCollapsed?.isActive = false
            middleTrailingConstraint?.isActive = true
        }
        collapseButton.image = NSImage(
            systemSymbolName: detailCollapsed ? "sidebar.right" : "sidebar.right",
            accessibilityDescription: nil)
        collapseButton.contentTintColor = detailCollapsed ? .secondaryLabelColor : nil
        // 搜索框的左缘原本绑在右栏左缘上。折叠后右栏被推出窗口，
        // 那条链会把搜索框和它右边的三个按钮一起拖出可视区 ——
        // 表现为「折叠后顶栏按钮全不见了，再也展不开」。
        // 折叠时改绑中栏右缘，展开时绑回右栏。
        rebindTitleToSidebar()

        containerNeedsLayout()
        // 中栏宽度变了，列数要重算
        DispatchQueue.main.async { [weak self] in
            self?.relayoutGridColumns()
            self?.syncDetailDocSize()
        }
    }

    /// 触发窗口重布局
    private func containerNeedsLayout() {
        NSApp.windows.first(where: { $0.frame.width > 500 })?
            .contentView?.needsLayout = true
    }

    /// 播放速度：属于「屏 × 素材」的属性，只影响当前选中的这项。
    @objc private func rateChanged() {
        let idx = rateControl.selectedSegment
        guard idx >= 0, idx < Adjustment.rateOptions.count else { return }
        applyPlaybackRate(Adjustment.rateOptions[idx])
    }

    /// 自定义速度输入：接受 "1.5"、"1.5x"、"150%" 这类写法。
    @objc private func rateFieldCommitted() {
        let raw = rateField.stringValue
            .replacingOccurrences(of: "×", with: "")
            .replacingOccurrences(of: "x", with: "")
            .trimmingCharacters(in: .whitespaces)
        let hadPercent = raw.contains("%")
        var v = Double(raw.replacingOccurrences(of: "%", with: "")) ?? 1.0
        // 写成 150% 时按百分比解释；否则按倍率
        if hadPercent { v = v / 100.0 }
        applyPlaybackRate(v)
    }

    /// 统一的速度落地点：夹紧范围、写入该屏该素材、应用、刷新。
    private func applyPlaybackRate(_ raw: Double) {
        guard let item = selectedItem, item.kind == .video else { return }
        // 0.25–2.0：再高硬件解码吃力、CPU 明显上升；再低几乎看不出画面在动
        let rate = max(0.25, min(2.0, raw))

        StateStore.shared.update { st in
            for s in self.targetScreens {
                let id = screenID(s)
                var adj = st.adjustment(display: id, item: item.path)
                adj.playbackRate = rate
                st.setAdjustment(adj, display: id, item: item.path)
            }
        }
        // 只改播放速率，不重建壁纸窗口 —— 重建会让视频从头开始
        WallpaperManager.shared.applyPlaybackRateTo(path: item.path)
        // 输入框要立刻显示**实际生效**的值：用户输入 3.00 会被夹到 2.0，
        // 若框里还留着 3.00，界面就在撒谎。
        rateField.stringValue = String(format: "%.2f", rate)
        refreshControls()
    }

    /// 静音开关：全局生效，不涉及任何单屏/单图状态。
    @objc private func muteChanged() {
        let muted = (muteCheck.state == .on)
        StateStore.shared.update { st in
            st.muted = muted
        }
        // 只改播放器的 isMuted，不重建窗口 —— 重建会打断正在播放的视频
        WallpaperManager.shared.setMuted(muted)
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

        // —— 应用菜单 ——
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appItem.submenu = appMenu
        appSubmenuApp = appMenu

        // —— 壁纸（文件级操作）——
        let wpItem = NSMenuItem(title: L10n.t("menu.wallpaperMenu"), action: nil, keyEquivalent: "")
        let wpSub = NSMenu()
        wpSub.delegate = self
        wpItem.submenu = wpSub
        wallpaperMenuApp = wpSub
        mainMenu.addItem(wpItem)

        // —— 预设 ——
        let preItem = NSMenuItem(title: L10n.t("nav.presets"), action: nil, keyEquivalent: "")
        let preSub = NSMenu()
        preSub.delegate = self
        preItem.submenu = preSub
        presetsMenuApp = preSub
        mainMenu.addItem(preItem)

        // —— 图库（浏览级操作）——
        let libItem = NSMenuItem(title: L10n.t("menu.libraryMenu"), action: nil, keyEquivalent: "")
        let libSub = NSMenu()
        libSub.delegate = self
        libItem.submenu = libSub
        libraryMenuApp = libSub
        mainMenu.addItem(libItem)

        // —— 播放 ——
        let playItem = NSMenuItem(title: L10n.t("menu.playback"), action: nil, keyEquivalent: "")
        let playSub = NSMenu()
        playSub.delegate = self
        playItem.submenu = playSub
        playbackMenuApp = playSub
        mainMenu.addItem(playItem)

        // —— 显示器 ——
        let dpItem = NSMenuItem(title: L10n.t("nav.displays"), action: nil, keyEquivalent: "")
        let dpSub = NSMenu()
        dpSub.delegate = self
        dpItem.submenu = dpSub
        displaysMenuApp = dpSub
        mainMenu.addItem(dpItem)

        // —— 缩放模式 ——
        let modeItem = NSMenuItem(title: L10n.t("menu.scaleMode"), action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        modeSub.delegate = self
        modeItem.submenu = modeSub
        scaleModeSubmenuApp = modeSub
        mainMenu.addItem(modeItem)

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

        sub.addItem(.separator())

        // 拖拽应用壁纸（开关）
        let dragApply = NSMenuItem(title: L10n.t("setting.dragToApply"),
                                   action: #selector(toggleDragToApply),
                                   keyEquivalent: "")
        dragApply.target = self
        dragApply.state = Settings.dragToApplyEnabled ? .on : .off
        sub.addItem(dragApply)
    }

    /// 开/关「拖拽壁纸到屏幕即应用」
    @objc private func toggleDragToApply() {
        Settings.dragToApplyEnabled.toggle()
    }

    // MARK: - 主菜单的动态子菜单

    /// 「播放」：暂停 + 停止/还原（文案随状态变化，必须动态构建）
    private func buildPlaybackMenu(into sub: NSMenu, isStatusMenu: Bool = false) {
        sub.removeAllItems()

        let pause = NSMenuItem(title: L10n.t("menu.pauseWallpaper"),
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = WallpaperManager.shared.isPaused ? .on : .off
        pause.isEnabled = !state.assignment.isEmpty
        if isStatusMenu { pauseMenuItem = pause } else { appPauseItem = pause }
        sub.addItem(pause)

        // 有壁纸时为「停止全部墙纸」，停掉之后变成「还原全部墙纸」
        let canRestore = state.assignment.isEmpty && state.canRestoreStopped
        let stop = NSMenuItem(title: L10n.t(canRestore ? "win.restoreAll" : "menu.stopAll"),
                              action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = canRestore || !state.assignment.isEmpty
        sub.addItem(stop)
    }

    /// 应用菜单：关于 / 设置项 / 隐藏 / 退出
    private func buildAppMenu(into sub: NSMenu) {
        sub.removeAllItems()

        sub.addItem(withTitle: L10n.t("menu.about"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")

        // 新手引导：空库时中栏会自动显示，但老用户已经过了那个阶段，
        // 需要一个随时能回看的入口。
        let guide = NSMenuItem(title: L10n.t("menu.guide"),
                               action: #selector(showQuickGuide), keyEquivalent: "")
        guide.target = self
        sub.addItem(guide)

        sub.addItem(.separator())

        // —— 设置项全部收进这里 ——
        let fs = NSMenuItem(title: L10n.t("menu.pauseOnFullscreen"),
                            action: #selector(toggleFullscreenPause), keyEquivalent: "")
        fs.target = self
        fs.state = FullscreenMonitor.shared.isEnabled ? .on : .off
        fullscreenMenuItem = fs
        sub.addItem(fs)

        let bat = NSMenuItem(title: L10n.t("menu.pauseOnBattery"),
                             action: #selector(togglePauseOnBattery), keyEquivalent: "")
        bat.target = self
        bat.state = Settings.pauseOnBattery ? .on : .off
        batteryMenuItem = bat
        sub.addItem(bat)

        let dragApply = NSMenuItem(title: L10n.t("setting.dragToApply"),
                                   action: #selector(toggleDragToApply), keyEquivalent: "")
        dragApply.target = self
        dragApply.state = Settings.dragToApplyEnabled ? .on : .off
        sub.addItem(dragApply)

        let auto = NSMenuItem(title: L10n.t("menu.launchAtLogin"),
                              action: #selector(toggleAutoStartMenu), keyEquivalent: "")
        auto.target = self
        auto.state = isAutoStartEnabled() ? .on : .off
        appMenuAutoItem = auto
        sub.addItem(auto)

        sub.addItem(.separator())

        sub.addItem(withTitle: L10n.t("menu.hide"),
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        sub.addItem(withTitle: L10n.t("menu.quit"),
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// 「壁纸」：文件级操作
    private func buildWallpaperMenu(into sub: NSMenu) {
        sub.removeAllItems()
        let hasItem = selectedItem != nil

        let add = NSMenuItem(title: L10n.t("win.addFiles"),
                             action: #selector(addFiles), keyEquivalent: "o")
        add.target = self
        sub.addItem(add)

        let refresh = NSMenuItem(title: L10n.t("library.refresh"),
                                 action: #selector(refreshLibraryNow), keyEquivalent: "r")
        refresh.target = self
        sub.addItem(refresh)

        sub.addItem(.separator())

        let revealFolder = NSMenuItem(title: L10n.t("library.revealFolder"),
                                      action: #selector(revealWallpaperFolder), keyEquivalent: "")
        revealFolder.target = self
        sub.addItem(revealFolder)

        let changeFolder = NSMenuItem(title: L10n.t("setting.changeFolder"),
                                      action: #selector(changeWallpaperFolder), keyEquivalent: "")
        changeFolder.target = self
        sub.addItem(changeFolder)

        sub.addItem(.separator())

        let assign = NSMenuItem(title: L10n.t("win.setWallpaper"),
                                action: #selector(assignToTarget), keyEquivalent: "")
        assign.target = self
        assign.isEnabled = hasItem
        sub.addItem(assign)

        let reveal = NSMenuItem(title: L10n.t("menu.reveal"),
                                action: #selector(revealInFinder), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = hasItem
        sub.addItem(reveal)

        let trash = NSMenuItem(title: L10n.t("win.removeFromLibrary"),
                               action: #selector(removeFromLibrary), keyEquivalent: "")
        trash.target = self
        trash.isEnabled = hasItem
        sub.addItem(trash)

    }

    /// 「显示器」：切换目标屏 + 清除壁纸
    private func buildDisplaysMenu(into sub: NSMenu) {
        sub.removeAllItems()

        let all = NSMenuItem(title: L10n.t("nav.allDisplays"),
                             action: #selector(selectAllDisplaysMenu), keyEquivalent: "0")
        all.target = self
        all.state = targetDisplayID.isEmpty ? .on : .off
        sub.addItem(all)

        if !screens.isEmpty {
            sub.addItem(.separator())
            for (i, s) in screens.enumerated() {
                let id = screenID(s)
                let it = NSMenuItem(title: screenTitle(s),
                                    action: #selector(selectDisplayMenu(_:)),
                                    keyEquivalent: i < 9 ? "\(i + 1)" : "")
                it.target = self
                it.representedObject = id
                it.state = (targetDisplayID == id) ? .on : .off
                sub.addItem(it)
            }
        }

        sub.addItem(.separator())

        let clearOne = NSMenuItem(title: L10n.t("win.clearCurrentDisplay"),
                                  action: #selector(clearCurrentDisplayWallpaper), keyEquivalent: "")
        clearOne.target = self
        clearOne.isEnabled = !targetDisplayID.isEmpty && state.assignment[targetDisplayID] != nil
        sub.addItem(clearOne)

        let clearAll = NSMenuItem(title: L10n.t("win.clearAllDisplays"),
                                  action: #selector(clearAllDisplaysWallpaper), keyEquivalent: "")
        clearAll.target = self
        clearAll.isEnabled = !state.assignment.isEmpty
        sub.addItem(clearAll)
    }

    /// 「图库」：分类跳转 + 排序 + 显示选项
    private func buildLibraryMenu(into sub: NSMenu) {
        sub.removeAllItems()

        let all = NSMenuItem(title: L10n.t("nav.libraryAll"),
                             action: #selector(selectLibraryMenu(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = ""
        if case .library(let c) = librarySelection, c == nil { all.state = .on }
        sub.addItem(all)

        for cat in wallpaperCategories() {
            let it = NSMenuItem(title: cat,
                                action: #selector(selectLibraryMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = cat
            if case .library(let c) = librarySelection, c == cat { it.state = .on }
            sub.addItem(it)
        }

        sub.addItem(.separator())

        let newCat = NSMenuItem(title: L10n.t("category.new"),
                                action: #selector(newCategory), keyEquivalent: "")
        newCat.target = self
        sub.addItem(newCat)

        sub.addItem(.separator())

        let byName = NSMenuItem(title: L10n.t("setting.sortByName"),
                                action: #selector(setSortKeyMenu(_:)), keyEquivalent: "")
        byName.target = self
        byName.representedObject = "name"
        byName.state = Settings.sortKey == "name" ? .on : .off
        sub.addItem(byName)

        let byDate = NSMenuItem(title: L10n.t("setting.sortByDate"),
                                action: #selector(setSortKeyMenu(_:)), keyEquivalent: "")
        byDate.target = self
        byDate.representedObject = "date"
        byDate.state = Settings.sortKey == "date" ? .on : .off
        sub.addItem(byDate)

        let asc = NSMenuItem(title: L10n.t("setting.sortAsc"),
                             action: #selector(setSortOrderMenu(_:)), keyEquivalent: "")
        asc.target = self
        asc.representedObject = "asc"
        asc.state = Settings.sortAscending ? .on : .off
        sub.addItem(asc)

        let desc = NSMenuItem(title: L10n.t("setting.sortDesc"),
                              action: #selector(setSortOrderMenu(_:)), keyEquivalent: "")
        desc.target = self
        desc.representedObject = "desc"
        desc.state = Settings.sortAscending ? .off : .on
        sub.addItem(desc)

        sub.addItem(.separator())

        let names = NSMenuItem(title: L10n.t("setting.showFileNames"),
                               action: #selector(toggleGridFileNames), keyEquivalent: "")
        names.target = self
        names.state = Settings.showGridFileNames ? .on : .off
        sub.addItem(names)
    }

    /// 「预设」：保存 + 逐个加载
    private func buildPresetsMenu(into sub: NSMenu) {
        sub.removeAllItems()

        let save = NSMenuItem(title: L10n.t("preset.saveCurrent"),
                              action: #selector(savePreset), keyEquivalent: "s")
        save.target = self
        sub.addItem(save)

        guard !state.presets.isEmpty else { return }
        sub.addItem(.separator())
        for p in state.presets {
            let it = NSMenuItem(title: p.name,
                                action: #selector(loadPresetMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.id
            sub.addItem(it)
        }
    }

    // MARK: - 动态菜单动作

    @objc private func selectAllDisplaysMenu() {
        sidebarSelectionChanged(.allDisplays)
        sidebar.select(.allDisplays)
    }

    @objc private func selectDisplayMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sidebarSelectionChanged(.display(id))
        sidebar.select(.display(id))
    }

    @objc private func selectLibraryMenu(_ sender: NSMenuItem) {
        let raw = (sender.representedObject as? String) ?? ""
        let value: String? = raw.isEmpty ? nil : raw
        sidebarSelectionChanged(.library(value))
        sidebar.select(.library(value))
    }

    @objc private func setSortKeyMenu(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Settings.sortKey = key
        resortLibraryInPlace()
        reloadLibrary()
    }

    @objc private func setSortOrderMenu(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        Settings.sortAscending = (v == "asc")
        resortLibraryInPlace()
        reloadLibrary()
    }

    @objc private func loadPresetMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = state.presets.first(where: { $0.id == id }) else { return }
        applyPreset(p)
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

        // —— 播放（动态构建：停止/还原的文案随状态变化）——
        let playItem = NSMenuItem(title: L10n.t("menu.playback"), action: nil, keyEquivalent: "")
        let playSub = NSMenu()
        playSub.delegate = self
        playItem.submenu = playSub
        playbackMenuStatus = playSub
        menu.addItem(playItem)

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

        // 侧栏状态点要跟着变：某块屏被全屏应用盖住时它应转为橙黄。
        // 之前这里只更新了已隐藏的底栏文字，所以圆点看起来「不刷新」。
        let st = displayStatusMap()
        sidebar.reload(presets: state.presets,
                       screens: screens,
                       categories: wallpaperCategories(),
                       statuses: st.perDisplay,
                       aggregate: st.aggregate,
                       selection: displaySelection,
                       librarySelection: librarySelection,
                       presetSelection: presetSelection,
                       categoryCovers: categoryCoverMap())

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

    /// 重算中栏宽度：拖左右栏时保持三栏之和 = 窗口宽，避免溢出撑大窗口。
    /// 中栏宽度由左右栏位置自然决定，不再需要显式计算。
    private func updateMiddleWidth() {}

    /// 把顶栏标题绑到左栏右缘（间距 8）。
    /// 必须在 sidebar 已加入视图层级之后调用，否则跨视图约束会崩。
    /// 把标题行（返回按钮 + 两行文字）绑到左栏右缘。
    ///
    /// 标题不再是裸的 NSTextField，而是一个含返回按钮的水平 stack ——
    /// 返回按钮隐藏时 stack 自动收窄，标题就贴到左缘，不需要额外分支。
    private func rebindTitleToSidebar() {
        guard let row = titleRowStack else { return }
        titleLeadingConstraint?.isActive = false
        // 与网格第一列左缘对齐：sidebar.trailing + 8（中栏起点）+ 16（网格内边距）
        let c = row.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24)
        c.isActive = true
        titleLeadingConstraint = c
    }

    @objc private func showPanel() {
        // 从菜单栏唤出面板时，把 Dock 图标一并恢复
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 点击输入框以外的地方时，结束编辑态。
    ///
    /// AppKit 不会自动这么做：文本框一旦成为第一响应者就会一直保持编辑态，
    /// 直到显式 resign。用户反馈「点了别处，搜索框仍处于待输入状态」即此。
    ///
    /// 实现要点：用本地事件监听而非逐个视图加 mouseDown，
    /// 这样按钮、侧栏、缩略图、空白区全都覆盖，且不影响控件自身的点击行为。
    /// 点击位置是否落在左栏内
    /// 这次点击是否需要清除预设选中。
    ///
    /// 只有「点右栏」时保留 —— 右栏承载「应用预设」等操作，
    /// 清除选中会让用户没法继续操作刚选中的预设。
    private func clickShouldClearPreset(_ event: NSEvent, window w: NSWindow) -> Bool {
        guard let hit = w.contentView?.hitTest(event.locationInWindow) else { return false }

        // 命中视图是否位于某个容器内
        func isInside(_ target: NSView?) -> Bool {
            guard let target else { return false }
            var v: NSView? = hit
            while let cur = v {
                if cur === target { return true }
                v = cur.superview
            }
            return false
        }

        if isInside(detailPaneView) { return false }   // 右栏：保留
        if isInside(sidebar) {
            // 点在左栏内部的预设行上由选中逻辑自己处理，这里不干预；
            // 点左栏其它位置（分类、显示器、空白）都清除。
            return true
        }
        return true                                     // 中栏及其它：清除
    }

    private func installClickToEndEditing() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let w = self.window else { return event }

            // 预设选中的清除规则：
            //   点中栏        → 清除（用户转去操作图库）
            //   点左栏其它处  → 清除（转去选分类/显示器）
            //   点右栏        → 保留（右栏有「应用预设」等针对预设的操作）
            if self.clickShouldClearPreset(event, window: w) {
                self.sidebar.clearPresetSelectionIfNeeded()
            }

            // 只有当焦点在文本框里时才需要处理
            guard w.firstResponder is NSTextView else { return event }

            // 判断点击位置是否落在某个可编辑文本框内；是的话保持编辑
            if let hit = w.contentView?.hitTest(event.locationInWindow) {
                var v: NSView? = hit
                while let cur = v {
                    if let tf = cur as? NSTextField, tf.isEditable {
                        return event        // 点的是输入框本身，正常处理
                    }
                    v = cur.superview
                }
            }

            // 点到别处：先提交当前编辑，再交还焦点
            w.makeFirstResponder(nil)
            return event
        }
    }

    // MARK: 窗口生命周期

    func windowDidChangeScreen(_ notification: Notification) {
        // 三栏布局窗口是可自由缩放的，换屏不应该改它的尺寸或位置：
        // 用户把它摆到哪里就是哪里。只需要让网格列数跟着新宽度走。
        relayoutGridColumns()
    }

    func windowDidMove(_ notification: Notification) {
        // 刻意什么都不做。
        //
        // 旧实现会在这里把窗口夹回该屏的 visibleFrame，导致两个问题：
        // ①窗口拖不到 Dock 下面（visibleFrame 已经把 Dock 扣掉了）；
        // ②换屏时还会被强制改高度，表现为「UI 自己往上跳」。
        // 新布局是可自由缩放的固定尺寸窗口，位置与大小完全交给用户。
    }

    /// 把系统红绿灯往里挪，避开侧栏面板的圆角。
    ///
    /// 系统默认把三个按钮钉在距窗口左/上各 8pt 处，而侧栏面板也从 8pt 起、
    /// 圆角 16 —— 按钮外角到圆角圆心 22.6pt > 16，正好压在弧线上被切。
    ///
    /// 关键：这个方法必须**幂等**，因为窗口每次布局/缩放后按钮位置都会被
    /// AppKit 重置回默认值。用「记录原始位置」而不是「累加偏移」实现，
    /// 重复调用不会把按钮越推越远（之前正是这个 bug 导致位置漂移）。
    private func alignTrafficLights(_ window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return }

        // AppKit 给这三个按钮的默认起点是 (8, 8)（窗口坐标系，原点左下）。
        // 目标：水平 +8、垂直 -8，落到 (16, 16) 附近，落在圆角内侧。
        // 直接按绝对值设置，不做累加 —— 幂等，重复调用安全。
        let targetY: CGFloat = 8 - 8
        var x: CGFloat = 16
        for b in [close, mini, zoom] {
            b.setFrameOrigin(NSPoint(x: x, y: targetY))
            x += b.frame.width + 6
        }
    }

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
        if menu === scaleModeSubmenu || menu === scaleModeSubmenuApp {
            rebuildScaleModeMenu(into: menu)
        } else if menu === settingsSubmenuStatus || menu === settingsSubmenuApp {
            buildSettingsItems(into: menu)
        } else if menu === appSubmenuApp {
            buildAppMenu(into: menu)
        } else if menu === playbackMenuStatus {
            buildPlaybackMenu(into: menu, isStatusMenu: true)
        } else if menu === playbackMenuApp {
            buildPlaybackMenu(into: menu)
        } else if menu === wallpaperMenuApp {
            buildWallpaperMenu(into: menu)
        } else if menu === displaysMenuApp {
            buildDisplaysMenu(into: menu)
        } else if menu === libraryMenuApp {
            buildLibraryMenu(into: menu)
        } else if menu === presetsMenuApp {
            buildPresetsMenu(into: menu)
        } else {
            refreshMenuStates()
        }
    }
}

/// 垂直居中 + 可控左右内边距的 NSTextFieldCell。
///
/// 关掉 NSTextField 的 border 后，标准 cell 会把文字画在框的上沿，
/// 看起来「文字没对齐」。重写 drawingRect 让它在整个 cell 高度内居中。
/// 垂直居中的搜索框 cell。
/// NSSearchField 必须用 NSSearchFieldCell 才能保留放大镜/清除按钮，
/// 所以不能直接换成 VerticallyCenteredFieldCell，只能子类化后覆写绘制矩形。
final class VerticallyCenteredSearchCell: NSSearchFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var r = super.drawingRect(forBounds: rect)
        let textH = attributedStringValue.size().height
        if textH > 0 && textH < r.height {
            let dy = (r.height - textH) / 2
            r.origin.y += dy
            r.size.height = textH
        }
        return r
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect),
                   in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect),
                     in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
final class VerticallyCenteredFieldCell: NSTextFieldCell {
    var horizontalInset: CGFloat = 7

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var r = super.drawingRect(forBounds: rect)
        let textH = attributedStringValue.size().height
        if textH > 0 && textH < r.height {
            let dy = (r.height - textH) / 2
            r.origin.y += dy
            r.size.height = textH
        }
        r.origin.x += horizontalInset
        r.size.width -= horizontalInset * 2
        return r
    }

    /// 编辑态与显示态用同一个矩形，否则点进去文字会跳位
    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

/// 原点在左上的容器：NSScrollView 里装普通 NSView 时原点在左下，
/// 滚动方向会反直觉，换 flipped 才能像网页一样从顶部开始往下滚。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    /// 布局时通知外部（右栏用它把自己的文档视图按内容重新量高）
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
