import AppKit

// ============================================================
//  ScreenDropOverlay — 拖拽壁纸时的「放到这块屏」提示
//
//  拖拽期间为每块屏幕挂一个透明无边框窗口，窗口中央显示一个
//  提示方块。方块本身不接收鼠标，拖拽由窗口的 NSDraggingDestination
//  接收（见 P5）。这样既能在任意屏幕上给出目标提示，又不会
//  铺满整个屏幕影响用户对桌面上下文的判断。
// ============================================================

/// 单块屏幕上的投放提示窗口。
final class ScreenDropOverlay: NSWindow {

    let screenRef: NSScreen

    private let card = NSView()
    private let blurView = NSVisualEffectView()
    private let dimView = NSView()
    private let borderView = DropTargetBorder()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// 方块尺寸（不随屏幕缩放，四块屏看起来一样大）
    private static let cardSize = NSSize(width: 320, height: 200)
    /// 窗口相对卡片的内边距（给描边与放大留余量）
    static let cardPadding: CGFloat = 14
    static var cardWidth: CGFloat { cardSize.width }
    static var cardHeight: CGFloat { cardSize.height }

    /// 松手时回调：把素材应用到这块屏
    var onDrop: ((String) -> Void)?

    /// 当前是否是命中屏（高亮态）
    private(set) var isTargeted = false

    init(screen: NSScreen) {
        self.screenRef = screen
        // 窗口只占卡片那么大，不铺满整屏。
        // 铺满会挡住下层窗口（左栏、图库、桌面）的拖拽目标，
        // 也会让人误以为整块屏都被占用了。
        // 窗口比卡片大一圈：描边、阴影、命中放大都需要余量，
        // 否则卡片贴着窗口边缘，右侧与顶部的边框会被裁掉。
        let pad = Self.cardPadding
        let cardRect = NSRect(x: 0, y: 0,
                              width: Self.cardSize.width + pad * 2,
                              height: Self.cardSize.height + pad * 2)
        super.init(contentRect: cardRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        let center = Self.cardCenter(on: screen)
        let winW = Self.cardSize.width + pad * 2
        let winH = Self.cardSize.height + pad * 2
        setFrameOrigin(NSPoint(x: center.x - winW / 2,
                               y: center.y - winH / 2))

        // 透明、无阴影、不抢焦点
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // 整个窗口默认不接收鼠标：它铺满整屏，若接收会把左栏、
        // 图库的拖拽目标全挡住。只有方块那一小块需要响应，
        // 由 contentView 的 hitTest 收窄（见 CardHostView）。
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false

        // 用可收窄命中范围的容器：方块外部的区域对鼠标「透明」，
        // 这样铺满整屏的 overlay 不会挡住下层窗口的拖拽目标。
        contentView = HitTestView()

        buildCard()
    }

    // MARK: - 构建

    private func buildCard() {
        // 窗口只有卡片大小，整个窗口都作为放置目标，不再需要收窄命中。
        guard let content = contentView else { return }
        if let hit = content as? HitTestView {
            hit.registerForDraggedTypes([WallpaperDrag.type])
            hit.onDrop = { [weak self] path in self?.onDrop?(path) }
        }

        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(card)

        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 16
        blurView.layer?.masksToBounds = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(blurView)

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dimView.layer?.cornerRadius = 16
        dimView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dimView)

        borderView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(borderView)

        iconView.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: iconView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: Self.cardSize.width),
            card.heightAnchor.constraint(equalToConstant: Self.cardSize.height),

            blurView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: card.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            dimView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: card.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            borderView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            borderView.topAnchor.constraint(equalTo: card.topAnchor),
            borderView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
        ])
    }

    /// 卡片在屏幕上的中心点：用 visibleFrame 避开 Dock 与菜单栏
    static func cardCenter(on screen: NSScreen) -> NSPoint {
        let v = screen.visibleFrame
        return NSPoint(x: v.midX, y: v.midY)
    }

    /// 方块在 contentView 坐标系中的矩形
    private func cardFrameInContent() -> NSRect {
        guard let content = contentView else { return .zero }
        let w = Self.cardSize.width, h = Self.cardSize.height
        return NSRect(x: (content.bounds.width - w) / 2,
                      y: (content.bounds.height - h) / 2,
                      width: w, height: h)
    }

    // MARK: - 状态

    /// 更新提示内容与高亮态。
    /// 只更新高亮样式（拖拽代理直接调用，不必重算文案）
    func applyTargetedStyle(_ targeted: Bool) {
        isTargeted = targeted
        let accent = NSColor.controlAccentColor
        borderView.strokeColor = targeted ? accent : NSColor.white.withAlphaComponent(0.18)
        borderView.lineWidth = targeted ? 3.0 : 1.0
        iconView.contentTintColor = targeted ? accent : .secondaryLabelColor
        titleLabel.textColor = targeted ? .labelColor : .secondaryLabelColor
        dimView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(targeted ? 0.10 : 0.22).cgColor
        alphaValue = targeted ? 1.0 : 0.72
    }

    func configure(screenName: String, resolution: String, targeted: Bool) {
        isTargeted = targeted
        titleLabel.stringValue = screenName
        detailLabel.stringValue = targeted
            ? L10n.t("dragTarget.release")
            : resolution

        let accent = NSColor.controlAccentColor
        // 待命态几乎不描边（只有一圈极淡的白），
        // 命中后才出现明显的强调色边框 —— 「放到这里」的信号要清晰。
        borderView.strokeColor = targeted ? accent : NSColor.white.withAlphaComponent(0.18)
        borderView.lineWidth = targeted ? 3.0 : 1.0

        iconView.contentTintColor = targeted ? accent : .secondaryLabelColor
        titleLabel.textColor = targeted ? .labelColor : .secondaryLabelColor
        dimView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(targeted ? 0.10 : 0.22).cgColor

        // 命中态靠「边框加粗 + 提亮」区分，不做缩放：
        // 缩放会让卡片超出窗口边界、边框被裁。
        alphaValue = targeted ? 1.0 : 0.72
    }

    /// 淡入：拖拽会话开始时调用。
    func fadeIn(animated: Bool = true) {
        alphaValue = 0
        orderFrontRegardless()
        guard animated else { alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    // MARK: - 动画

    /// 淡出并清理：拖拽结束时必须调用，否则会留下幽灵窗口。
    func fadeOut(then completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }
}


/// 只在指定区域内响应命中测试的容器。
/// 铺满整屏的 overlay 窗口必须用它，否则会把下层窗口的拖拽目标全挡住。
final class HitTestView: NSView {
    var hitTestOverride: ((NSPoint) -> NSView?)?
    /// 素材被放到这块屏上
    var onDrop: ((String) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestOverride?(point)
    }
}

extension HitTestView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [WallpaperDrag.type]) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [WallpaperDrag.type]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let path = sender.draggingPasteboard.string(forType: WallpaperDrag.type)
        else { return false }
        onDrop?(path)
        return true
    }
}

/// 方块外圈的圆角描边（命中时变强调色并加粗）。
final class DropTargetBorder: NSView {
    var strokeColor: NSColor = .white {
        didSet { applyLayer() }
    }
    var lineWidth: CGFloat = 1.5 {
        didSet { applyLayer() }
    }

    var cornerRadius: CGFloat = 16 {
        didSet { applyLayer() }
    }

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
        layer?.masksToBounds = false
        applyLayer()
    }

    // 用 CALayer 的边框而不是自绘：
    // 自绘要等 bounds 落定，首次显示时可能只画出一部分（实测左+底有边、顶+右没有）。
    private func applyLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = lineWidth
        layer?.borderColor = strokeColor.cgColor
    }
}
