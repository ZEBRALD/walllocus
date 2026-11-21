import AppKit

// ============================================================
//  PresetThumbStack — 预设卡片左侧的「叠起来的几张壁纸」
//
//  最多取 3 张缩略图，从后到前依次缩小并偏移，做出叠放观感。
//  素材缩略图复用 ThumbnailStore（160px、NSCache），不额外解码大图。
// ============================================================

final class PresetThumbStack: NSView {

    var paths: [String] = [] {
        didSet { rebuild() }
    }

    private var imageLayers: [CALayer] = []
    private let maxLayers = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    private func rebuild() {
        imageLayers.forEach { $0.removeFromSuperlayer() }
        imageLayers.removeAll()
        guard let host = layer else { return }

        let shown = Array(paths.prefix(maxLayers))
        guard !shown.isEmpty else {
            // 没有任何可用素材时画一个虚线占位
            let ph = CALayer()
            ph.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
            ph.cornerRadius = 4
            ph.frame = bounds.insetBy(dx: 6, dy: 4)
            host.addSublayer(ph)
            imageLayers.append(ph)
            return
        }

        // 从后往前画：越靠后越小、偏移越多
        for (idx, path) in shown.enumerated().reversed() {
            let depth = CGFloat(idx)
            let inset = 3.0 * depth
            let card = CALayer()
            card.cornerRadius = 4
            card.masksToBounds = true
            card.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            card.borderWidth = 1
            card.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
            card.frame = CGRect(x: inset,
                                y: bounds.height - inset - 36,
                                width: bounds.width - inset * 2 - 4,
                                height: 36)
            card.contentsGravity = .resizeAspectFill
            host.addSublayer(card)
            imageLayers.append(card)

            // 异步填图；回调里核对这一层是否还活着（避免复用串图）
            let target = card
            ThumbnailStore.shared.thumbnail(for: path) { image in
                guard let image else { return }
                // 卡片可能已被重建，确认它还在图层树里
                guard target.superlayer === host else { return }
                target.contents = image
            }
        }
    }

    override func layout() {
        super.layout()
        // 尺寸变化后重排（bounds 变了，frame 计算要重来）
        rebuild()
    }
}
