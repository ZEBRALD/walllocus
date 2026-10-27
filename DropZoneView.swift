import AppKit

// ============================================================
//  DropZoneView — 承接从访达拖进来的图片/视频
//
//  作为窗口的 contentView：整个面板区域都可作为放置目标。
//  拖入时画一圈虚线高亮并把数量报给用户，松手前就能看出会发生什么。
// ============================================================

enum MediaTypes {
    static let imageExts = Rendering.imageExtensions
    static let videoExts: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
        "wmv", "flv", "3gp", "ts", "m2ts", "asf", "ogv", "rmvb"
    ]

    /// 是否是本应用能用的素材（只看扩展名，不解码）
    static func isSupported(_ path: String) -> Bool {
        let e = (path as NSString).pathExtension.lowercased()
        return imageExts.contains(e) || videoExts.contains(e)
    }
}

/// 自绘虚线边框。
///
/// 路径必须由本视图自己维护：如果在父视图的 layout() 里读 borderView.bounds，
/// 那一刻 Auto Layout 往往还没把尺寸传导下来，bounds 仍是零，路径就成了空——
/// 表现是模糊和遮罩都正常，唯独看不见边框（实测如此）。
final class DashedBorderView: NSView {

    override var isFlipped: Bool { true }

    var strokeColor: NSColor = .controlAccentColor {
        didSet { shape.strokeColor = strokeColor.cgColor }
    }

    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        common()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        common()
    }

    private func common() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shape.fillColor = nil
        shape.lineWidth = 3
        shape.lineDashPattern = [8, 5]
        shape.strokeColor = strokeColor.cgColor
        layer?.addSublayer(shape)
    }

    override func layout() {
        super.layout()
        let r = bounds
        guard r.width > 2, r.height > 2 else { return }
        // 关掉隐式动画，否则每次布局虚线都会"游动"一下
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = r
        shape.path = CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5),
                            cornerWidth: 10, cornerHeight: 10,
                            transform: nil)
        CATransaction.commit()
    }
}

final class DropZoneView: NSView {

    /// 用户松手后回调可用的素材路径
    var onDrop: (([String]) -> Void)?

    private let overlay = NSView()
    /// 毛玻璃：把底层素材库糊掉，让上层提示跳出来
    private let blurView = NSVisualEffectView()
    /// 半透明压暗层，进一步提升文字对比度
    private let dimView = NSView()
    /// 虚线边框（自管理路径）
    private let borderView = DashedBorderView()
    /// 图标与文字背后的圆角底板，保证在任何壁纸上都看得清
    private weak var textCard: NSStackView?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var isActive = false
    /// 每次拖入的候选数量，用于在 draggingUpdated 里刷新文案
    private var supportedCount = 0
    private var rejectedCount = 0

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
        // 只接收文件 URL；字符串/文本之类的拖入不会触发
        registerForDraggedTypes([.fileURL])

        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 10
        overlay.layer?.masksToBounds = true
        // 只用 alphaValue 表示显隐：再设 layer.opacity 会变成两套状态，
        // 动画只改其中一个，结果两者不一致（实测整层会实心显示）。
        overlay.alphaValue = 0
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        addSubview(overlay)

        // 叠放顺序（由下到上）：模糊 → 压暗 → 虚线框 → 文字。
        // 先做模糊+压暗，上层提示才有足够对比度；只描一圈虚线时，
        // 底层素材库的缩略图会把文字淹没。

        // 1) 毛玻璃：.withinWindow 模糊的是同窗口内位于其下方的视图，
        //    正是我们要模糊的素材库；.behindWindow 会去模糊桌面，不适用。
        blurView.material = .hudWindow
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(blurView)

        // 2) 再压一层半透明黑，把底层进一步压下去，提升文字对比度。
        //    深浅色模式下都是"变暗"，行为一致。
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dimView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(dimView)

        // 3) 虚线边框：用独立子视图承载 CAShapeLayer，
        //    这样它一定叠在 blur/dim 之上（同一父视图按添加顺序排列）。
        borderView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(borderView)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 30, bottom: 18, right: 30)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        textCard = stack

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: overlay.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),

            dimView.topAnchor.constraint(equalTo: overlay.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),

            borderView.topAnchor.constraint(equalTo: overlay.topAnchor),
            borderView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            borderView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),

            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
    }

    /// 保证浮层永远排在最上层。
    ///
    /// 外部会先创建本视图、再 addSubview(内容)，那样内容会排在浮层之上，
    /// 把模糊与遮罩整块盖住，只剩边缘虚线露出来。实测就是这样：
    /// 浮层 alpha=1 却完全看不到变暗效果。所以每次加入子视图后把浮层提到最前。
    override func addSubview(_ view: NSView) {
        super.addSubview(view)
        guard view !== overlay, overlay.superview === self else { return }
        super.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    /// 布局时把浮层重新提到最前，并更新虚线路径
    override func layout() {
        super.layout()
        if overlay.superview === self {
            super.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }


    // MARK: 视觉反馈

    private func showOverlay(valid: Bool) {
        let symbol = valid ? "square.and.arrow.down.on.square" : "exclamationmark.triangle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)

        let accent = valid ? NSColor.controlAccentColor : NSColor.systemRed
        borderView.strokeColor = accent
        iconView.contentTintColor = accent
        // 拒绝时压暗层带一点红，和"可以放"在余光里就能区分开
        dimView.layer?.backgroundColor = valid
            ? NSColor.black.withAlphaComponent(0.22).cgColor
            : NSColor.systemRed.withAlphaComponent(0.20).cgColor
        // 有了模糊+压暗打底，文字底板可以更轻，避免层层叠加显脏
        textCard?.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.72).cgColor
        textCard?.layer?.borderWidth = 1
        textCard?.layer?.borderColor = accent.withAlphaComponent(0.45).cgColor

        if valid {
            titleLabel.stringValue = L10n.t("drop.title", supportedCount)
            detailLabel.stringValue = rejectedCount > 0
                ? L10n.t("drop.partial", rejectedCount)
                : L10n.t("drop.hint")
        } else {
            titleLabel.stringValue = L10n.t("drop.unsupported")
            detailLabel.stringValue = L10n.t("drop.supportedTypes")
        }

        if !isActive {
            isActive = true
            overlay.isHidden = false
            // 目标值先落地，再做淡入；否则动画未推进时视图仍是透明的
            overlay.alphaValue = 1
            overlay.layer?.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            overlay.layer?.add(fade, forKey: "fadeIn")
        } else {
            // 已经显示，内容变化时无需重复动画
            overlay.alphaValue = 1
        }
    }

    private func hideOverlay() {
        guard isActive else { return }
        isActive = false
        overlay.alphaValue = 0
        overlay.layer?.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.15
        overlay.layer?.add(fade, forKey: "fadeOut")
        overlay.isHidden = true
    }

    // MARK: 拖放

    /// 从拖拽会话里取出文件 URL，并拆成「可用 / 不支持」两组
    private func classify(_ sender: NSDraggingInfo) -> (ok: [String], bad: [String]) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL] else {
            return ([], [])
        }
        var ok: [String] = []
        var bad: [String] = []
        for u in urls {
            if MediaTypes.isSupported(u.path) { ok.append(u.path) } else { bad.append(u.path) }
        }
        return (ok, bad)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let (ok, bad) = classify(sender)
        supportedCount = ok.count
        rejectedCount = bad.count
        guard !ok.isEmpty else {
            if !bad.isEmpty { showOverlay(valid: false) }
            return []
        }
        showOverlay(valid: true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 拖拽过程中可能从别的窗口继续加文件，数量会变
        let (ok, bad) = classify(sender)
        let changed = ok.count != supportedCount || bad.count != rejectedCount
        supportedCount = ok.count
        rejectedCount = bad.count
        guard !ok.isEmpty else {
            if !bad.isEmpty { showOverlay(valid: false) } else { hideOverlay() }
            return []
        }
        if changed { showOverlay(valid: true) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideOverlay()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !classify(sender).ok.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideOverlay()
        let (ok, _) = classify(sender)
        guard !ok.isEmpty else { return false }
        onDrop?(ok)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideOverlay()
    }
}
