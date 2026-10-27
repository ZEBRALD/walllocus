import AppKit

// ============================================================
//  ThumbnailStrip — 壁纸库横向缩略图条
//
//  只负责「展示 + 选择」，不做任何壁纸应用动作。
//  点击缩略图 → onSelect(path)，由控制器决定后续行为。
// ============================================================

// MARK: - 单个缩略图卡片

final class ThumbnailItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    static let cardSize = NSSize(width: 112, height: 92)
    private static let thumbHeight: CGFloat = 70

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badge = NSImageView()

    /// 当前卡片承载的素材路径。异步缩略图回来时用它判断是否已被复用。
    private(set) var representedPath: String?

    override var isSelected: Bool {
        didSet { updateSelectionRing() }
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        v.layer?.borderWidth = 2
        v.layer?.borderColor = NSColor.clear.cgColor
        view = v

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumbView)

        nameLabel.font = NSFont.systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(nameLabel)

        // 视频角标：白色播放符号压在右下角
        badge.image = NSImage(systemSymbolName: "play.circle.fill",
                              accessibilityDescription: nil)
        badge.contentTintColor = NSColor(white: 1, alpha: 0.92)
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(badge)

        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            thumbView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            thumbView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            thumbView.heightAnchor.constraint(equalToConstant: Self.thumbHeight),

            nameLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),

            badge.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: -4),
            badge.widthAnchor.constraint(equalToConstant: 16),
            badge.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func updateSelectionRing() {
        view.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }

    /// 绑定一个素材。先填已缓存的图（避免闪烁），再异步取。
    func configure(path: String, name: String, kind: MediaKind) {
        representedPath = path
        nameLabel.stringValue = name
        badge.isHidden = (kind != .video)
        updateSelectionRing()

        // 文件在添加后被移动/删除的情况：直接给「缺失」态，不去解码，
        // 也避免用户对着一张空白卡片猜为什么没反应。
        guard FileManager.default.fileExists(atPath: path) else {
            thumbView.image = Self.placeholder(symbol: "questionmark.square.dashed")
            nameLabel.textColor = .systemRed
            badge.isHidden = true
            return
        }
        nameLabel.textColor = .secondaryLabelColor

        if let cached = ThumbnailStore.shared.cachedImage(for: path) {
            thumbView.image = NSImage(cgImage: cached,
                                      size: NSSize(width: cached.width, height: cached.height))
        } else {
            thumbView.image = nil
        }

        ThumbnailStore.shared.thumbnail(for: path) { [weak self] image in
            // 关键：异步回来时这张卡片可能已被复用到别的素材上，
            // 路径不匹配就丢弃，否则会串图。
            guard let self, self.representedPath == path else { return }
            guard let image else {
                self.thumbView.image = Self.placeholder(symbol: "exclamationmark.triangle")
                return
            }
            self.thumbView.image = NSImage(cgImage: image,
                                           size: NSSize(width: image.width, height: image.height))
        }
    }

    /// 占位图标，保持与缩略图相近的观感
    private static func placeholder(symbol: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedPath = nil
        thumbView.image = nil
        nameLabel.stringValue = ""
        // 缺失态用的是红字，复用前必须复位，否则会把颜色带到下一个素材上
        nameLabel.textColor = .secondaryLabelColor
        badge.isHidden = true
        isSelected = false
    }
}

// MARK: - 缩略图条容器

final class ThumbnailStrip: NSView {

    /// 用户点击某张缩略图（只上报路径，是否应用由调用方决定）
    var onSelect: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private var items: [LibraryItem] = []
    private var suppressCallback = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = ThumbnailItem.cardSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        collection.collectionViewLayout = layout
        collection.register(ThumbnailItem.self,
                            forItemWithIdentifier: ThumbnailItem.identifier)
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            collection.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            collection.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            collection.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
        ])
    }

    // MARK: 对外接口

    func reload(_ newItems: [LibraryItem], selectedPath: String?) {
        items = newItems
        collection.reloadData()
        select(path: selectedPath, notify: false)
    }

    /// 选中某个路径。notify = false 用于「由外部同步过来」的场景，避免回调成环。
    func select(path: String?, notify: Bool = false) {
        guard let path, let idx = items.firstIndex(where: { $0.path == path }) else {
            suppressCallback = true
            collection.deselectAll(nil)
            suppressCallback = false
            return
        }
        let set = Set([IndexPath(item: idx, section: 0)])
        suppressCallback = true
        // 必须先 deselectAll：selectItems 是「追加选择」语义，
        // 不清旧选择会导致多张卡片同时高亮（实测选中数会累加到 2+）。
        collection.deselectAll(nil)
        collection.selectItems(at: set, scrollPosition: .nearestHorizontalEdge)
        suppressCallback = false
        if notify {
            onSelect?(path)
        }
    }

    var preferredHeight: CGFloat { ThumbnailItem.cardSize.height + 16 }
}

// MARK: - 数据源与代理

extension ThumbnailStrip: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ cv: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: ThumbnailItem.identifier,
                               for: indexPath) as! ThumbnailItem
        let entry = items[indexPath.item]
        item.configure(path: entry.path, name: entry.name, kind: entry.kind)
        return item
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !suppressCallback,
              let idx = indexPaths.first?.item,
              idx < items.count else { return }
        onSelect?(items[idx].path)
    }
}
