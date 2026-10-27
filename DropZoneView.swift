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

final class DropZoneView: NSView {

    /// 用户松手后回调可用的素材路径
    var onDrop: (([String]) -> Void)?

    private let overlay = NSView()
    /// 虚线边框。CALayer 的 border 画不了虚线，必须用 CAShapeLayer 描路径。
    private let dashLayer = CAShapeLayer()
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
        // 故意不填底色：拖拽时用户仍要能看见下面的素材库。
        // 醒目度交给虚线边框和中间的文字底板。
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        // 只用 alphaValue 表示显隐：再设 layer.opacity 会变成两套状态，
        // 动画只改其中一个，结果两者不一致（实测整层会实心显示）。
        overlay.alphaValue = 0
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        addSubview(overlay)

        dashLayer.fillColor = nil
        dashLayer.lineWidth = 3
        dashLayer.lineDashPattern = [8, 5]
        dashLayer.strokeColor = NSColor.controlAccentColor.cgColor
        overlay.layer?.addSublayer(dashLayer)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 26, bottom: 16, right: 26)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        textCard = stack

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

    /// overlay 尺寸由 Auto Layout 决定，虚线路径要跟着更新
    override func layout() {
        super.layout()
        let r = overlay.bounds
        guard r.width > 0, r.height > 0 else { return }
        dashLayer.frame = r
        let path = CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5),
                          cornerWidth: 10, cornerHeight: 10, transform: nil)
        dashLayer.path = path
    }

    // MARK: 视觉反馈

    private func showOverlay(valid: Bool) {
        let symbol = valid ? "square.and.arrow.down.on.square" : "exclamationmark.triangle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)

        let accent = valid ? NSColor.controlAccentColor : NSColor.systemRed
        dashLayer.strokeColor = accent.cgColor
        iconView.contentTintColor = accent
        // 底板用系统窗口底色，深浅色模式都合适
        textCard?.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.96).cgColor
        textCard?.layer?.borderWidth = 1
        textCard?.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor

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
