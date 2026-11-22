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
    /// 单击：立刻通知选中（不等双击判定）
    var onSingleClick: (() -> Void)?
    /// 双击：进入重命名
    var onDoubleClick: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        // 单击：在 mouseDown 就提交选中，求即时反馈。
        // 只在 clickCount == 1 时选中；第二次按下不能再次触发，
        // 否则「双击」会被拆成两次单击。
        if event.clickCount == 1 {
            onSingleClick?()
        }
        // 刻意不调 super.mouseDown：
        // NSCollectionViewItem 的默认实现会在按下时把焦点交给视图链上最近的
        // 可编辑控件（右栏的名称框 / 数值框 / 顶栏搜索框），
        // 表现为「只是点了一下界面，输入框就进入了编辑态」。
        // 选中与双击我们都自己处理了，不需要它转发。
    }

    override func mouseUp(with event: NSEvent) {
        // 双击：抬手时按 clickCount 判定，进入重命名。
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        // 同样不转发，避免 super 再次改焦点
    }
}

// MARK: - 单个卡片

final class ThumbnailItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    /// 卡片基准尺寸（不改，作为等比缩放的比例来源）。
    static let baseCardSize = NSSize(width: 112, height: 92)
    /// 当前实际尺寸，随窗口大小变化。
    static var cardSize = NSSize(width: 112, height: 92)
    /// 缩略图高度跟随卡片尺寸：卡片变高时缩略图同步变高，
    /// 否则卡片宽/高比会失真（列数看起来会跳变）。
    /// 卡片高 92 时原值为 70，即缩略图约占卡片高的 76%。
    static var thumbHeight: CGFloat { round(cardSize.height * 0.76) }

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    /// 「正在使用」角标：左上角小圆点
    private let inUseDot = NSView()
    /// 缩略图高度约束（卡片尺寸变化时更新它，让缩略图跟着变大变小）
    private var thumbHeightConstraint: NSLayoutConstraint?

    private(set) var representedPath: String?
    /// 单击卡片（即时选中，不等双击判定窗口）
    var onSingleClick: ((String) -> Void)?
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
        v.onSingleClick = { [weak self] in
            guard let self, let path = self.representedPath else { return }
            self.onSingleClick?(path)
        }
        v.onDoubleClick = { [weak self] in
            guard let self, let path = self.representedPath else { return }
            self.onDoubleClick?(path)
        }
        v.wantsLayer = true
        // 照片 App 的图片没有卡片边框，只有一个圆角矩形的图片本身。
        // 选中态仍用描边，但平时不画边框。
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0
        v.layer?.borderColor = NSColor.clear.cgColor
        view = v

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 8
        thumbView.layer?.masksToBounds = true
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
            thumbHeightConstraintSetup(v),

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

        // 这里刻意不装 NSClickGestureRecognizer：
        // 手势识别器会先拦截鼠标事件做判定，判定窗口约等于系统双击间隔（~500ms），
        // 期间 CardView 收不到 mouseDown/mouseUp，表现就是「点一下要缓半秒才亮」。
        // 双击改由 CardView 依据 event.clickCount 自己判断。
    }

    private func updateSelectionRing() {
        // 平时无边框，选中时才有强调色描边（与照片一致）
        view.layer?.borderWidth = isSelected ? 3 : 0
        view.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }

    /// 绑定素材。inUse = 是否正被某块屏使用。
    func configure(path: String, title: String, originalName: String, kind: MediaKind, inUse: Bool) {
        // 卡片尺寸会随窗口缩放变化，缩略图高度必须同步，否则卡片会被压扁/拉伸
        thumbHeightConstraint?.constant = Self.thumbHeight
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

    /// 卡片尺寸变化后重新设定缩略图高度（由 ThumbnailGrid 调用）
    func refreshCardSize() {
        thumbHeightConstraint?.constant = Self.thumbHeight
        view.needsLayout = true
    }

    /// 建立并保存缩略图高度约束，返回它供 NSLayoutConstraint.activate 使用
    private func thumbHeightConstraintSetup(_ v: NSView) -> NSLayoutConstraint {
        let c = thumbView.heightAnchor.constraint(equalToConstant: Self.thumbHeight)
        thumbHeightConstraint = c
        return c
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
    private var collectionScrollView: NSScrollView?

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
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        // 照片是通铺布局：左右几乎不留边，右侧只给滚动条让一点
        layout.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 10)

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
        // 窗口太小时 25 个排不下一屏，需要滚动条
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
            // 贴底太挤，留一点呼吸空间（用户反馈「切页按钮太靠下」）
            pager.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            collection.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            collection.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            // 高度不在这里约束：NSCollectionView 作为 documentView 时，
            // Auto Layout 无法从内容推导出高度。改为在 updateCollectionHeight()
            // 里按「行数 × 行高 + 间距」手动设置 frame，这样超出可视区就能滚动。
        ])
        collectionScrollView = scroll
    }

    // MARK: 对外接口

    /// 设置每页行列数（由外部按可用高度决定）
    /// 网格固定为 4 列 × 5 行；这里按可用空间算出能让它们都放下的最大卡片尺寸。
    /// 取「宽度均分」与「高度均分」中较小的那个，保证两个方向都不溢出。
    /// 按可用宽度与列数算出卡片尺寸。
    /// 宽度必须精确等于「可用宽 / 列数」：NSCollectionViewFlowLayout 只要一行塞得下
    /// 就会多塞，卡片稍窄就会出现比设定更多的列（实测出现过 5 列、7 列）。
    /// 设置内容顶部内边距。
    ///
    /// 图库现在从面板顶端开始（图片能滚到顶部渐变模糊层下方），
    /// 但初始位置要避开那层，否则第一行会被模糊遮住。
    func setTopContentInset(_ inset: CGFloat) {
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
    }

    /// 网格真正可用的宽度（集合视图的实际宽度）。
    /// 用它而不是从窗口尺寸反推：后者是估算，窗口缩放时会与真实宽度
    /// 有几像素偏差，导致 FlowLayout 时而塞得下 5 列、时而只剩 4 列 ——
    /// 也就是用户看到的「4 列 5 列来回跳」。
    var availableGridWidth: CGFloat {
        let w = collection.bounds.width
        return w > 0 ? w : scroll.contentView.bounds.width
    }

    func applyCardSize(availableWidth: CGFloat, columns: Int) {
        guard columns > 0, availableWidth > 0 else { return }
        // 必须与 setGrid 里的 minimumInteritemSpacing / sectionInset 保持一致，
        // 否则算出来的卡片偏宽，一行塞不下第 5 个，实测只显示 4 列。
        let spacing: CGFloat = 10          // = layout.minimumInteritemSpacing
        let insetW: CGFloat = 10           // = sectionInset.left(0) + right(10)
        // 减 1pt 吸收浮点误差：FlowLayout 只要差一点点就会把这一行
        // 判成「放不下」，表现为列数在 4/5 之间来回跳。
        let usable = availableWidth - insetW - spacing * CGFloat(columns - 1) - 1
        let w = floor(usable / CGFloat(columns))
        // 下限放宽到 44：要求「列数恒为 5」，窗口再窄也只能靠缩小卡片来让位。
        // 原来卡在 80，窄窗口下 5×80 超出可用宽，FlowLayout 就会掉到 4 列甚至 3 列。
        let clamped = max(44, min(220, w))
        let base = ThumbnailItem.baseCardSize
        let newSize = NSSize(width: clamped,
                             height: round(clamped * base.height / base.width))

        // 用 layout 的真实 itemSize 做比较，而不是静态变量 cardSize：
        // 两者可能不同步（setGrid 重建 layout 后 cardSize 没变），
        // 拿 cardSize 判断会导致 layout 永不更新。
        let current = (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize
            ?? ThumbnailItem.cardSize
        guard abs(newSize.width - current.width) > 0.5 else { return }
        ThumbnailItem.cardSize = newSize
        if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = newSize
            // 同时校正间距：两者必须与算宽度时用的参数一致，
            // 否则 FlowLayout 会按旧间距排出比预期少的列数。
            layout.minimumInteritemSpacing = 10
            layout.minimumLineSpacing = 12
            layout.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 10)
            layout.invalidateLayout()
            collection.collectionViewLayout = layout
        }
        for case let item as ThumbnailItem in collection.visibleItems() {
            item.refreshCardSize()
        }
        collection.layoutSubtreeIfNeeded()
    }

    func setGrid(columns: Int, rows: Int) {
        let newCols = max(1, columns)
        let newRows = max(1, rows)
        let changed = (newCols != self.columns || newRows != self.rows)
        self.columns = newCols
        self.rows = newRows

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.itemSize = ThumbnailItem.cardSize
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        // 照片是通铺布局：左右几乎不留边，右侧只给滚动条让一点
        layout.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 10)
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
                selectedPath: String?,
                resetPage: Bool = false) {
        let contentChanged = (items.count != allItems.count)
            || (items.map { $0.path } != allItems.map { $0.path })
        allItems = items
        inUsePaths = inUse
        // 素材集合变了（搜索过滤、增删）就回到第 1 页，
        // 否则会停在一个已经不存在的页码上（实测出现过只剩 6 项却显示 2/2）。
        if resetPage || contentChanged { page = 0 }
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
            // 没有可选项：只在确实有选中项时才清除，避免无谓的刷新
            if !collection.selectionIndexPaths.isEmpty {
                suppressCallback = true
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                collection.deselectAll(nil)
                NSAnimationContext.endGrouping()
                suppressCallback = false
            }
            return
        }

        let target = IndexPath(item: idx, section: 0)
        // 已经是目标状态时什么都不做：点同一张卡片不应该触发任何重绘
        if collection.selectionIndexPaths == [target] {
            if notify { onSelect?(path) }
            return
        }

        // 关键：deselectAll + selectItems 会在同一帧内各触发一轮 isSelected 回调，
        // 视觉上就是「旧框消失 → 新框出现」的两段闪烁，看起来像反应慢。
        // 包进一次 duration=0 的动画分组，让两批更新合并成一次重绘。
        suppressCallback = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        collection.deselectAll(nil)
        collection.selectItems(at: Set([target]), scrollPosition: [])
        NSAnimationContext.endGrouping()
        suppressCallback = false

        if notify { onSelect?(path) }
    }

    /// 每页数量取自设置（默认 25）。与行列数解绑：窗口窄时行数更多，靠滚动查看。
    /// 不再分页：一页 = 全部素材。
    /// 有了分类之后，每个分类下的数量本就有限，翻页反而碍事；
    /// 连续滚动更接近照片 App 的浏览方式。
    var pageSize: Int { max(1, allItems.count) }

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

    /// 按当前行数与卡片尺寸设置 collection 高度，使其能滚动。
    /// documentView 交给 Auto Layout 处理高度在这条链上不可靠（实测滚不动），
    /// 所以直接设 frame。
    private func updateCollectionHeight() {
        guard let scroll = collectionScrollView else { return }
        let w = scroll.contentView.bounds.width
        guard w > 0 else { return }
        let visibleCount = pageItems.count
        let usedCols = max(1, columns)
        let usedRows = max(1, Int(ceil(Double(visibleCount) / Double(usedCols))))
        let rowH = ThumbnailItem.cardSize.height + 8
        let h = max(CGFloat(usedRows) * rowH + 8, scroll.contentView.bounds.height)
        collection.frame = NSRect(x: 0, y: 0, width: w, height: h)
    }

    private func refreshPage() {
        clampPage()
        let start = page * pageSize
        let end = min(start + pageSize, allItems.count)
        pageItems = start < end ? Array(allItems[start..<end]) : []
        collection.reloadData()
        updatePager()
        // 内容变了，高度也要跟着变（决定是否出现滚动条）
        DispatchQueue.main.async { [weak self] in
            self?.updateCollectionHeight()
        }
    }

    /// 布局变化（窗口缩放）后重新计算高度
    override func layout() {
        super.layout()
        updateCollectionHeight()
    }

    private func updatePager() {
        let total = pageCount
        pageLabel.stringValue = L10n.t("pager.summary", page + 1, total, allItems.count)
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
        item.onSingleClick = { [weak self] p in self?.onSelect?(p) }
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
