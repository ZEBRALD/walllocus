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

/// 不参与鼠标事件响应的容器。
/// alphaValue 为 0 / isHidden 状态下仍可能参与 hitTest 并吞事件，
/// 表现为「底下的图库滚不动」——显式返回 nil 彻底放行。
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class DropZoneView: NSView {

    /// 用户松手后回调可用的素材路径
    var onDrop: (([String]) -> Void)?

    /// 覆盖全窗口的拖放接收层。
    ///
    /// 绿加号由系统按「光标下的拖放接收者」绘制。卡在缩略图、预览图这类
    /// 子视图上时，系统问的是它们（不接收文件），于是加号时有时无。
    /// hitTest 拦不住这一点 —— AppKit 找接收者不走 hitTest。
    /// 可靠做法是在拖拽期间把这一层提到最上层，让所有位置都命中它。
    private let dragSink = DragSinkView()

    /// 拖拽提示浮层：外层不响应鼠标事件（否则会吞掉图库的滚动）
    private let overlay = PassthroughView()
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
    /// 延时隐藏计时器：拖拽经过窗口边缘时 entered/exited 会反复触发，
    /// 每次都立刻隐藏会让浮层闪个不停。
    private var hideTimer: Timer?
    /// 拖拽中「是否真的离开了窗口」的轮询
    private var exitWatch: Timer?
    /// 探测「系统是否正在拖拽文件」的轮询
    private var dragWatch: Timer?
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

        // 拖放接收层：铺满窗口，拖拽期间提到最上层
        dragSink.handler = self
        dragSink.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragSink)
        NSLayoutConstraint.activate([
            dragSink.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragSink.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragSink.topAnchor.constraint(equalTo: topAnchor),
            dragSink.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        startDragWatch()

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
        // 只在浮层被盖住时才重新置顶，避免无谓的移除-再加（会重置动画状态）
        if subviews.last !== overlay {
            super.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    /// 布局时确保浮层在最前。
    ///
    /// 关键：只在「浮层不是最后一个子视图」时才重排。
    /// 每次 layout 都 addSubview(positioned:.above) 会把视图先移除再加回，
    /// 这会重置 alphaValue 与动画状态 —— 拖拽时 layout 被频繁触发，
    /// 浮层就闪个不停（而且动画永远播不完）。
    override func layout() {
        super.layout()
        guard overlay.superview === self else { return }
        if subviews.last !== overlay {
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

        // 不做淡入动画：拖拽期间 showOverlay 会被反复调用，
        // 每次从 0 淡入就是「闪一下」的来源。直接切到不透明。
        isActive = true
        overlay.layer?.removeAllAnimations()
        overlay.isHidden = false
        overlay.alphaValue = 1
        startExitWatch()
    }

    private func hideOverlay() {
        guard isActive else { return }
        isActive = false
        stopExitWatch()
        // 与显示一样不做动画：动画收尾会与下一次显示竞争，
        // 表现为浮层反复显隐。直接瞬切最稳。
        overlay.layer?.removeAllAnimations()
        overlay.alphaValue = 0
        overlay.isHidden = true
    }

    /// 探测系统是否正在拖拽文件，据此开关接收层。
    ///
    /// 拖放开始没有本地通知可监听（draggingEntered 可能被别的子视图吃掉），
    /// 所以用剪贴板探测：NSDragPboard 上有文件 URL 就说明文件拖拽在途。
    private func startDragWatch() {
        dragWatch?.invalidate()
        var consecutiveMisses = 0
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            let dragging = NSPasteboard(name: .drag).availableType(from: [.fileURL]) != nil

            if dragging {
                consecutiveMisses = 0
            } else {
                // 拖拽期间粘贴板偶有瞬时读空：要连续多次读不到才算真的结束，
                // 否则接收层会闪断，绿加号随之消失（伴随焦点跳变）。
                consecutiveMisses += 1
                guard consecutiveMisses >= 4 else { return }
            }

            guard self.dragSink.isEnabled != dragging else { return }
            self.dragSink.isEnabled = dragging
            if dragging {
                self.addSubview(self.dragSink, positioned: .above, relativeTo: nil)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragWatch = t
    }

    /// 轮询兜底：拖拽期间若鼠标真的移出窗口，就收起浮层。
    ///
    /// 不能靠 draggingExited —— 它会在光标移入任何子视图时也触发，
    /// 导致「压在缩略图上没提示」。这里用全局鼠标位置做权威判断。
    private func startExitWatch() {
        exitWatch?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let win = self.window, self.isActive else { return }
            let p = NSEvent.mouseLocation
            if !NSMouseInRect(p, win.frame, false) {
                self.hideOverlay()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        exitWatch = t
    }

    private func stopExitWatch() {
        exitWatch?.invalidate()
        exitWatch = nil
    }

    /// 延时隐藏：吃掉 entered/exited 的抖动
    private func scheduleHideOverlay() {
        hideTimer?.invalidate()
        let t = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.hideOverlay()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func cancelScheduledHide() {
        hideTimer?.invalidate()
        hideTimer = nil
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
        // 库内素材拖回窗口时不该被当成「导入外部文件」：
        // 文件本来就在壁纸文件夹里，导入是空操作，弹出浮层反而干扰。
        if sender.draggingPasteboard.availableType(from: [WallpaperDrag.type]) != nil {
            // 库内素材拖回：不导入，也不要留着「导入」浮层
            cancelScheduledHide()
            hideOverlay()
            return []
        }
        let (ok, bad) = classify(sender)
        supportedCount = ok.count
        rejectedCount = bad.count
        guard !ok.isEmpty else {
            if !bad.isEmpty { showOverlay(valid: false) }
            return []
        }
        cancelScheduledHide()
        showOverlay(valid: true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 库内素材（自有类型）一律不当作导入：
        // 这里也必须判断，否则 entered 返回 [] 之后 updated 仍会走 classify，
        // 把「导入」浮层闪一下又收掉。
        if sender.draggingPasteboard.availableType(from: [WallpaperDrag.type]) != nil {
            return []
        }
        // 每次更新都取消待隐藏，拖拽在窗口内持续期间浮层不会消失
        cancelScheduledHide()
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
        // 刻意不在这里隐藏浮层。
        //
        // AppKit 在光标移入任何「参与命中测试的子视图」时都会发 exited
        // （缩略图卡片、右栏预览图、按钮等），但它们明明还在窗口内 ——
        // 按 exited 隐藏就会出现「压在这些视图上没提示、在缝隙里有提示」
        // 这种断续表现。
        //
        // 浮层的收起交给两个确定的时机：
        //   · performDragOperation / concludeDragOperation（放置完成）
        //   · 鼠标抬起的兜底监听（拖放被取消/失败）
        // 拖拽中不断重复 showOverlay 的成本可以忽略。
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 库内素材不是导入，直接拒绝
        if sender.draggingPasteboard.availableType(from: [WallpaperDrag.type]) != nil {
            return false
        }
        return !classify(sender).ok.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cancelScheduledHide()
        hideOverlay()
        // 库内素材不导入
        if sender.draggingPasteboard.availableType(from: [WallpaperDrag.type]) != nil {
            return false
        }
        let (ok, _) = classify(sender)
        guard !ok.isEmpty else { return false }
        onDrop?(ok)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        cancelScheduledHide()
        hideOverlay()
    }
}

/// 覆盖整个窗口的拖放接收层，只在拖拽期间生效。
///
/// AppKit 把拖放事件送给「光标下的视图链上第一个注册了该类型的视图」，
/// 而不是送给我们希望的视图。窗口里铺满了会参与命中的子视图，
/// 光标压在它们上面时拖放就落到它们身上 —— 绿加号也因此时有时无。
///
/// 这一层平时 hitTest 返回 nil（完全不挡下层鼠标操作），
/// 拖拽期间被提到最上层并且参与命中，保证任何位置都落到它这里。
final class DragSinkView: NSView {

    weak var handler: DropZoneView?

    /// 是否处于「接受拖放」状态
    var isEnabled = false {
        didSet { if oldValue != isEnabled { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        common()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        common()
    }

    private func common() {
        registerForDraggedTypes([.fileURL])
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        handler?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        handler?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        handler?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handler?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handler?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        handler?.concludeDragOperation(sender)
    }
}

