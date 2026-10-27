import AppKit

// ============================================================
//  ThumbnailGrid — 壁纸库网格（分页）
//
//  布局：N 列 × M 行，每页固定容量，底部「上一页 / 页码 / 下一页」。
//  为什么分页而不是滚动：图库大时一维横滚要翻十几屏，网格+分页能
//  把「我在哪、总共多少」讲清楚，且不需要自定义滚轮映射。
//
//  只负责展示与选择，不做任何壁纸应用动作。
// ============================================================

// MARK: - 卡片容器视图

/// 只有 NSView 能通过 menu(for:) 参与右键菜单；
/// NSCollectionViewItem 是 NSResponder，不处理鼠标事件，
/// 所以卡片根视图用这个子类把右键转出去。
final class CardView: NSView {
    var onRightClick: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onRightClick?()
    }
}

// MARK: - 单个卡片

final class ThumbnailItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    static let cardSize = NSSize(width: 112, height: 92)
    private static let thumbHeight: CGFloat = 70

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    /// 「正在使用」角标：左上角小圆点
    private let inUseDot = NSView()

    private(set) var representedPath: String?
    /// 双击卡片（用于进入重命名）
    var onDoubleClick: ((String) -> Void)?
    /// 右键卡片，由外部提供菜单
    var onContextMenu: ((String, NSView) -> NSMenu?)?

    override var isSelected: Bool {
        didSet { updateSelectionRing() }
    }

    override func loadView() {
        let v = CardView()
        v.onRightClick = { [weak self] in
            guard let self, let path = self.representedPath else { return nil }
            return self.onContextMenu?(path, self.view)
        }
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

        // 视频角标
        badge.image = NSImage(systemSymbolName: "play.circle.fill",
                              accessibilityDescription: nil)
        badge.contentTintColor = NSColor(white: 1, alpha: 0.92)
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(badge)

        // 「正在使用」圆点：绿色小圆，位于缩略图左上角
        inUseDot.wantsLayer = true
        inUseDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        inUseDot.layer?.cornerRadius = 4
        inUseDot.layer?.borderWidth = 1.5
        inUseDot.layer?.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        inUseDot.isHidden = true
        inUseDot.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(inUseDot)

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

            inUseDot.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: 5),
            inUseDot.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 5),
            inUseDot.widthAnchor.constraint(equalToConstant: 8),
            inUseDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        // 双击进入重命名。单击仍由 collection view 处理选中，
        // 所以这里只用 doubleClick 手势，不干扰选择。
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        dbl.numberOfClicksRequired = 2
        v.addGestureRecognizer(dbl)
    }

    @objc private func handleDoubleClick() {
        guard let path = representedPath else { return }
        onDoubleClick?(path)
    }

    private func updateSelectionRing() {
        view.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }

    /// 绑定素材。inUse = 是否正被某块屏使用。
    func configure(path: String, title: String, originalName: String, kind: MediaKind, inUse: Bool) {
        representedPath = path
        nameLabel.stringValue = title
        badge.isHidden = (kind != .video)
        inUseDot.isHidden = !inUse
        updateSelectionRing()

        // 悬停提示：改名后原始文件名在界面上就看不到了，
        // 这里补回来，方便对照 Finder 里的文件。
        var tip = title
        if title != originalName {
            tip += "\n" + L10n.t("tip.originalFile") + originalName
        }
        tip += "\n" + kind.label
        if inUse { tip += " · " + L10n.t("tip.inUse") }
        if !FileManager.default.fileExists(atPath: path) {
            tip += "\n" + L10n.t("tip.missing")
        }
        view.toolTip = tip

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
            // 异步回来时卡片可能已被复用到别的素材上，路径不匹配就丢弃
            guard let self, self.representedPath == path else { return }
            guard let image else {
                self.thumbView.image = Self.placeholder(symbol: "exclamationmark.triangle")
                return
            }
            self.thumbView.image = NSImage(cgImage: image,
                                           size: NSSize(width: image.width, height: image.height))
        }
    }

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
        nameLabel.textColor = .secondaryLabelColor
        badge.isHidden = true
        inUseDot.isHidden = true
        isSelected = false
    }
}

// MARK: - 网格容器

final class ThumbnailGrid: NSView {

    /// 用户点击某个卡片（只上报路径，是否应用由调用方决定）
    var onSelect: ((String) -> Void)?
    /// 用户右键卡片（用于重命名菜单）
    var onContextMenu: ((String, NSView) -> NSMenu?)?
    /// 用户双击卡片（进入重命名）
    var onDoubleClick: ((String) -> Void)?

    /// 每页容量由外部按可用空间设定
    private(set) var columns = 4
    private(set) var rows = 3
    private var page = 0

    private var allItems: [LibraryItem] = []
    private var inUsePaths: Set<String> = []
    private var pageItems: [LibraryItem] = []

    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let pager = NSStackView()
    private let prevButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")
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
        layout.scrollDirection = .vertical
        layout.itemSize = ThumbnailItem.cardSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

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
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // 分页条
        prevButton.bezelStyle = .rounded
        prevButton.controlSize = .small
        prevButton.target = self
        prevButton.action = #selector(goPrev)
        nextButton.bezelStyle = .rounded
        nextButton.controlSize = .small
        nextButton.target = self
        nextButton.action = #selector(goNext)
        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center

        pager.orientation = .horizontal
        pager.spacing = 8
        pager.alignment = .centerY
        pager.translatesAutoresizingMaskIntoConstraints = false
        pager.addArrangedSubview(prevButton)
        pager.addArrangedSubview(pageLabel)
        pager.addArrangedSubview(nextButton)
        addSubview(pager)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            pager.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            pager.centerXAnchor.constraint(equalTo: centerXAnchor),
            pager.bottomAnchor.constraint(equalTo: bottomAnchor),

            collection.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            collection.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
        ])
    }

    // MARK: 对外接口

    /// 设置每页行列数（由外部按可用高度决定）
    func setGrid(columns: Int, rows: Int) {
        let newCols = max(1, columns)
        let newRows = max(1, rows)
        let changed = (newCols != self.columns || newRows != self.rows)
        self.columns = newCols
        self.rows = newRows

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.itemSize = ThumbnailItem.cardSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        collection.collectionViewLayout = layout

        // 行列数变了，每页能装的数量就变了，必须重新切片。
        // 否则 pageItems 还是按旧容量切的（例如原来 1x4 切出 4 项，
        // 换成 3x4 后仍只显示 4 项），而 pageCount 已按新容量算出 1，
        // 页码又停在 0，下一页按钮直接失效。实测就是这样。
        if changed && !allItems.isEmpty {
            clampPage()
            refreshPage()
        }
    }

    /// 把 page 夹到合法范围内（容量或素材数变化后可能越界）
    private func clampPage() {
        page = min(max(0, page), max(0, pageCount - 1))
    }

    func reload(_ items: [LibraryItem],
                inUse: Set<String>,
                selectedPath: String?) {
        allItems = items
        inUsePaths = inUse
        // 让当前选中项所在页成为可见页，避免「选中了但看不到」
        if let path = selectedPath,
           let idx = items.firstIndex(where: { $0.path == path }) {
            page = min(idx / max(1, pageSize), max(0, pageCount - 1))
        }
        clampPage()
        refreshPage()
    }

    func select(path: String?, notify: Bool = false) {
        guard let path,
              let idx = pageItems.firstIndex(where: { $0.path == path }) else {
            suppressCallback = true
            collection.deselectAll(nil)
            suppressCallback = false
            return
        }
        let set = Set([IndexPath(item: idx, section: 0)])
        suppressCallback = true
        collection.deselectAll(nil)
        collection.selectItems(at: set, scrollPosition: [])
        suppressCallback = false
        if notify { onSelect?(path) }
    }

    var pageSize: Int { columns * rows }

    var pageCount: Int {
        guard pageSize > 0, !allItems.isEmpty else { return 1 }
        return (allItems.count + pageSize - 1) / pageSize
    }

    /// 高度由行数决定：每行 92 + 间距 8，加边距与分页条
    func preferredHeight() -> CGFloat {
        let rowsH = CGFloat(rows) * (ThumbnailItem.cardSize.height + 8) + 8
        return rowsH + 28   // 分页条高度
    }

    // MARK: 内部分页

    private func refreshPage() {
        clampPage()
        let start = page * pageSize
        let end = min(start + pageSize, allItems.count)
        pageItems = start < end ? Array(allItems[start..<end]) : []
        collection.reloadData()
        updatePager()
    }

    private func updatePager() {
        let total = pageCount
        pageLabel.stringValue = "\(page + 1) / \(total)   (\(allItems.count) 项)"
        prevButton.isEnabled = page > 0
        nextButton.isEnabled = page < total - 1
        // 只有一页时把整条分页器隐藏，避免占地方
        pager.isHidden = (total <= 1)
    }

    @objc private func goPrev() {
        guard page > 0 else { return }
        page -= 1
        refreshPage()
    }

    @objc private func goNext() {
        guard page < pageCount - 1 else { return }
        page += 1
        refreshPage()
    }

    /// 仅用于测试/诊断：当前可见的条目数
    var visibleCount: Int { pageItems.count }
    var currentPageIndex: Int { page }
    var totalPages: Int { pageCount }
}

// MARK: - 数据源与代理

extension ThumbnailGrid: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ cv: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        pageItems.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: ThumbnailItem.identifier,
                               for: indexPath) as! ThumbnailItem
        let entry = pageItems[indexPath.item]
        item.configure(path: entry.path,
                       title: entry.displayName,
                       originalName: entry.name,
                       kind: entry.kind,
                       inUse: inUsePaths.contains(entry.path))
        item.onDoubleClick = { [weak self] p in self?.onDoubleClick?(p) }
        item.onContextMenu = { [weak self] p, v in self?.onContextMenu?(p, v) }
        return item
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !suppressCallback,
              let idx = indexPaths.first?.item,
              idx < pageItems.count else { return }
        onSelect?(pageItems[idx].path)
    }
}
