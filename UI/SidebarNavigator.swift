import AppKit

// ============================================================
//  SidebarNavigator — 左侧导航：预设 + 显示器
//
//  两者放在同一个 NSOutlineView 里，因为它们是同一类东西：
//  「一份配置的应用范围」。预设是跨屏的一整套，显示器是单屏。
//  选中谁，中间网格就显示它当前在用哪张，右侧就调它的参数。
//  单一 selection 天然保证了两者互斥。
// ============================================================

/// 显示器当前的壁纸状态，用于侧栏右侧的小圆点。
enum DisplayStatus {
    case active      // 正在显示壁纸 → 绿
    case paused      // 已暂停（手动/全屏/电池）→ 橙黄
    case empty       // 未应用壁纸 → 白/灰

    var color: NSColor {
        switch self {
        case .active: return .systemGreen
        case .paused: return .systemOrange
        case .empty:  return NSColor(white: 0.75, alpha: 0.9)
        }
    }
}

enum SidebarSelection: Equatable {
    case preset(String)      // WallpaperPreset.id
    case display(String)     // 显示器 UUID；空串代表"全部显示器"
    case allDisplays
    /// 壁纸库分类筛选：nil = 全部，非 nil = 该子文件夹名
    case library(String?)
}

/// 把图片等比放大到铺满自身边界，并居中裁掉多余部分。
///
/// NSImageView 的 .scaleProportionallyUpOrDown 是「装进去不裁」，
/// 竖图会在两侧留白，在方形小格里看就是「没铺满」。
/// 这里用自绘实现 fill 语义，效果与照片 App 的分类缩略图一致。
final class FillImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    /// 图标模式：居中绘制、不裁切（空分类的占位图标用）
    var isIconMode = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, bounds.width > 0, bounds.height > 0 else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.clip(to: bounds)

        let srcW = image.size.width
        let srcH = image.size.height
        guard srcW > 0, srcH > 0 else { ctx.restoreGState(); return }

        if isIconMode {
            // 图标：等比装进去，居中
            let scale = min(bounds.width / srcW, bounds.height / srcH)
            let dw = srcW * scale, dh = srcH * scale
            image.draw(in: NSRect(x: (bounds.width - dw) / 2, y: (bounds.height - dh) / 2,
                                  width: dw, height: dh),
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            ctx.restoreGState()
            return
        }

        // 等比放大到刚好铺满，再居中
        let scale = max(bounds.width / srcW, bounds.height / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let rect = NSRect(x: (bounds.width - drawW) / 2,
                          y: (bounds.height - drawH) / 2,
                          width: drawW,
                          height: drawH)
        image.draw(in: rect,
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1,
                   respectFlipped: true,
                   hints: nil)
        ctx.restoreGState()
    }
}

final class SidebarNavigator: NSView {

    /// 选中项变化
    var onSelect: ((SidebarSelection) -> Void)?
    /// 点「保存当前为预设」
    var onSavePreset: (() -> Void)?
    /// 预设右键菜单（传入 preset id）
    var onPresetMenu: ((String, NSView) -> NSMenu?)?
    /// 点「新建分类」
    var onNewCategory: (() -> Void)?

    /// 更新面板顶部的标题与副标题
    func setHeader(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }

    private let scroll = NSScrollView()
    private let outline = ClickOutlineView()
    /// 三组各自独立的选中项（组内单选）
    private var selectedDisplay: SidebarSelection?
    private var selectedLibrary: SidebarSelection?
    private var selectedPreset: SidebarSelection?
    private var presets: [WallpaperPreset] = []
    private var screens: [NSScreen] = []
    private var categories: [String] = []
    /// 每个分类的封面图路径（取该分类第一张素材），用于渲染缩略图方块
    private var categoryCovers: [String: String] = [:]
    /// 面板顶部的大标题与副标题（原在顶栏，现移入侧栏内部）
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// 每个显示器 id → 状态（由 main.swift 注入）
    var displayStatuses: [String: DisplayStatus] = [:]
    /// 「全部显示器」的聚合状态
    var aggregateStatus: DisplayStatus = .empty
    private var suppressCallback = false

    /// 顶层节点：预设分组、显示器分组
    private final class Node {
        enum Kind {
            case group(String)
            case preset(WallpaperPreset)
            case display(String, String)   // (id, 标题)
            case allDisplays
            case savePreset
            case library(String?)          // nil = 全部
            case newCategory
        }
        let kind: Kind
        var children: [Node] = []
        init(_ kind: Kind) { self.kind = kind }
    }
    /// 底部信息区（当前选中项的名称 + 素材）
    private let infoBox = NSView()
    private let infoTitle = NSTextField(labelWithString: "")
    private let infoSubtitle = NSTextField(labelWithString: "")
    private let libraryGroup = Node(.group("library"))
    private let presetGroup = Node(.group("preset"))
    private let displayGroup = Node(.group("display"))
    /// 分组顺序：由设置决定，默认「显示器 > 壁纸库 > 预设」。
    /// 每次读取都按当前设置排序，这样改设置后只需 reload 即可生效。
    private var roots: [Node] {
        let all: [(String, Node)] = [
            ("display", displayGroup),
            ("library", libraryGroup),
            ("preset", presetGroup),
        ]
        let order = Settings.groupOrder
        var result: [Node] = []
        for key in order {
            if let hit = all.first(where: { $0.0 == key })?.1, !result.contains(where: { $0 === hit }) {
                result.append(hit)
            }
        }
        // 兜底：设置里漏掉的分组也补上，避免整块消失
        for pair in all where !result.contains(where: { $0 === pair.1 }) {
            result.append(pair.1)
        }
        return result
    }

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
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 左栏不再叠玻璃：底层已经铺满整窗并模糊了壁纸，
        // 再套一层会让它被模糊两次、比中栏暗。
        // 「浮起」由圆角 + 描边表达。
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.clear.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 与右栏一致的 liquid glass 描边（侧栏的玻璃是自建的，不过 addGlass）
        let rim = GlassRimView()
        rim.cornerRadius = 16
        // 描边随环境色变化：采样面板左上方一小块背景，染色到边框上。
        // 底色保持不变，只有边框跟着冷暖走（Vorssaint 的效果）。
        AmbientColorSampler.shared.onChange = { [weak rim] c in
            rim?.ambientColor = c
        }
        rim.ambientColor = AmbientColorSampler.shared.color
        rim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rim)
        NSLayoutConstraint.activate([
            rim.topAnchor.constraint(equalTo: topAnchor),
            rim.leadingAnchor.constraint(equalTo: leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: trailingAnchor),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])


        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .sourceList
        // 照片 App 的选中态是「圆角胶囊包住内容」，不是整行铺满。
        // sourceList 样式会铺满整行，这里改用 inset 的普通高亮。
        outline.selectionHighlightStyle = .regular
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        // 显示器 / 壁纸库 / 预设 三组各自独立选中，
        // 所以 outline 需要支持多选（组内仍由我们维持单选）。
        outline.allowsMultipleSelection = true
        // 点空白处：只取消预设的选中
        outline.onBlankClick = { [weak self] in
            guard let self else { return }
            // 只有预设组会因点空白而取消选中；
            // 显示器与壁纸库的组合（用哪张图、投到哪块屏）必须一直有效。
            self.selectedPreset = nil
            self.syncOutlineSelection()
        }
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(selectionChanged)
        // 直接按点击的行分发，覆盖「点一下就取消选中」的那些行
        outline.onClickRow = { [weak self] row in
            guard let self,
                  let node = self.outline.item(atRow: row) as? Node else { return }
            switch node.kind {
            case .newCategory:
                self.onNewCategory?()
            case .savePreset:
                self.onSavePreset?()
            case .group:
                break
            case .allDisplays:
                self.selectedDisplay = .allDisplays
                self.syncOutlineSelection()
                self.onSelect?(.allDisplays)
            case .display(let id, _):
                self.selectedDisplay = .display(id)
                self.syncOutlineSelection()
                self.onSelect?(.display(id))
            case .library(let cat):
                self.selectedLibrary = .library(cat)
                self.syncOutlineSelection()
                self.onSelect?(.library(cat))
            case .preset(let p):
                self.selectedPreset = .preset(p.id)
                self.syncOutlineSelection()
                self.onSelect?(.preset(p.id))
            }
        }
        // 右键：预设行给「应用 / 重命名 / 删除」，其它行不弹菜单
        outline.onMenuRow = { [weak self] row, view in
            guard let self,
                  let node = self.outline.item(atRow: row) as? Node else { return nil }
            if case .preset(let p) = node.kind {
                return self.onPresetMenu?(p.id, view)
            }
            return nil
        }
        outline.autoresizesOutlineColumn = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        // 与系统其它 App 一致：滚动时浮现、停手后淡出。
        // 之前只设了 hasVerticalScroller，缺少这两项，滚动条不会按 overlay 方式出现。
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .allowed
        // 内容高度不够时不强行撑高，也不让 outline 被压缩
        outline.autoresizingMask = [.width]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // ── 底部信息区：显示当前选中显示器/预设的名称与素材 ──
        infoBox.wantsLayer = true
        infoBox.layer?.cornerRadius = 8
        infoBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.22).cgColor
        infoBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoBox)

        infoTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        infoTitle.lineBreakMode = .byTruncatingTail
        infoTitle.translatesAutoresizingMaskIntoConstraints = false
        infoBox.addSubview(infoTitle)

        infoSubtitle.font = NSFont.systemFont(ofSize: 10)
        infoSubtitle.textColor = .secondaryLabelColor
        infoSubtitle.lineBreakMode = .byTruncatingMiddle
        infoSubtitle.translatesAutoresizingMaskIntoConstraints = false
        infoBox.addSubview(infoSubtitle)

        NSLayoutConstraint.activate([
            infoBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            infoBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            infoBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            infoTitle.leadingAnchor.constraint(equalTo: infoBox.leadingAnchor, constant: 10),
            infoTitle.trailingAnchor.constraint(equalTo: infoBox.trailingAnchor, constant: -10),
            infoTitle.topAnchor.constraint(equalTo: infoBox.topAnchor, constant: 8),

            infoSubtitle.leadingAnchor.constraint(equalTo: infoTitle.leadingAnchor),
            infoSubtitle.trailingAnchor.constraint(equalTo: infoTitle.trailingAnchor),
            infoSubtitle.topAnchor.constraint(equalTo: infoTitle.bottomAnchor, constant: 3),
            infoSubtitle.bottomAnchor.constraint(equalTo: infoBox.bottomAnchor, constant: -8),
        ])

        // 标题区：红绿灯下方显示「当前分类 / 素材数」。
        // 这块在面板内部，所以红绿灯看起来嵌在左栏里（照片 App 的排布）。
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            // 面板本身贴窗口边（红绿灯锁死在内侧），
            // 所有视觉边距都由内容缩进承担
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // 顶部 40 给红绿灯（系统固定位置），标题从 46 开始
            // 面板已在 logo 之下，内部不再需要为红绿灯留白
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])

        // 内部滚动视图要跟着父视图一起裁圆，否则它铺满矩形、
        // 会把 10pt 圆角整个盖住（看起来还是直角）。
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 16
        scroll.layer?.masksToBounds = true
        // 透明背景：让整栏颜色一致，不要出现「标题区深、列表区浅」的断层
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        outline.backgroundColor = .clear

        NSLayoutConstraint.activate([
            // scroll 从顶栏下方开始：这样列表第一行不会被浮层压住，
            // 而左栏的毛玻璃背景由外层视图负责铺满到窗口顶端。
            // 顶部让位：红绿灯区(~40) + 标题区(~52)
            // 面板已经从窗口顶端开始，红绿灯就嵌在它里面（照片 App 的做法）
            // 红绿灯区(40) + 标题区(56)
            // 标题已移到中栏顶部，左栏直接显示库/预设/显示器列表
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            // 横向不再内缩：让滚动条贴到面板右缘，与中栏、右栏保持一致。
            // 选中条与边缘的呼吸由 cell 自己的左右内边距承担。
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            // 底部让出选中项信息区
            scroll.bottomAnchor.constraint(equalTo: infoBox.topAnchor, constant: -8),
        ])
    }

    // MARK: 数据

    /// 更新底部信息区（当前选中显示器/预设）。
    func setInfo(title: String, subtitle: String) {
        infoTitle.stringValue = title
        infoSubtitle.stringValue = subtitle
        infoBox.isHidden = title.isEmpty && subtitle.isEmpty
    }

    func reload(presets: [WallpaperPreset],
                screens: [NSScreen],
                categories: [String] = [],
                statuses: [String: DisplayStatus] = [:],
                aggregate: DisplayStatus = .empty,
                selection: SidebarSelection?,
                displaySelection: SidebarSelection? = nil,
                librarySelection: SidebarSelection? = nil,
                presetSelection: SidebarSelection? = nil,
                categoryCovers: [String: String] = [:]) {
        self.presets = presets
        self.categoryCovers = categoryCovers
        self.screens = screens
        self.categories = categories
        self.displayStatuses = statuses
        self.aggregateStatus = aggregate

        // 壁纸库：全部 + 各分类 + 新建
        libraryGroup.children = [Node(.library(nil))]
        libraryGroup.children += categories.map { Node(.library($0)) }
        libraryGroup.children.append(Node(.newCategory))

        presetGroup.children = presets.map { Node(.preset($0)) }
        presetGroup.children.append(Node(.savePreset))

        var displayNodes: [Node] = [Node(.allDisplays)]
        for s in screens {
            displayNodes.append(Node(.display(screenIDOf(s), screenTitleOf(s))))
        }
        displayGroup.children = displayNodes

        outline.reloadData()
        // 分组默认展开
        for root in roots { outline.expandItem(root) }
        // 让 NSScrollView 重新计算可滚区域：
        // 预设/显示器数量变化后，若不刷新，滚动条可能不出现或长度不对。
        outline.sizeLastColumnToFit()
        scroll.reflectScrolledClipView(scroll.contentView)
        select(selection, notify: false)
    }

    /// 按选择项定位并高亮（notify=false 表示由外部同步过来，不回抛）
    func select(_ selection: SidebarSelection?, notify: Bool = false) {
        guard let selection else { return }
        // 按组更新：只替换同组的选中项，另外两组的选中不动。
        suppressCallback = !notify
        defer { suppressCallback = false }
        switch selection {
        case .allDisplays, .display:
            selectedDisplay = selection
        case .library:
            selectedLibrary = selection
        case .preset:
            selectedPreset = selection
        }
        syncOutlineSelection()
    }

    /// 把三组记录状态同步到 outline 的多选上
    private func syncOutlineSelection() {
        var rows = IndexSet()
        for sel in [selectedDisplay, selectedLibrary, selectedPreset].compactMap({ $0 }) {
            if let node = findNode(for: sel) {
                let r = outline.row(forItem: node)
                if r >= 0 { rows.insert(r) }
            }
        }
        // 已经是这个集合就什么都不做。
        // selectRowIndexes(byExtendingSelection: false) 会「先全部清空再重新选中」，
        // 即使目标集合与现状相同，未受影响的另两组也会闪一帧蓝框。
        guard rows != outline.selectedRowIndexes else { return }

        let wasSuppressed = suppressCallback
        suppressCallback = true
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        suppressCallback = wasSuppressed
    }

    /// 点击左栏以外的区域时调用：只清预设选中。
    /// 显示器与壁纸库是工作状态（在哪块屏看哪张图），点了别处也必须保持。
    func clearPresetSelectionIfNeeded() {
        guard selectedPreset != nil else { return }
        selectedPreset = nil
        syncOutlineSelection()
    }

    private func findNode(for selection: SidebarSelection) -> Node? {
        switch selection {
        case .allDisplays:
            return displayGroup.children.first { if case .allDisplays = $0.kind { return true }; return false }
        case .display(let id):
            return displayGroup.children.first {
                if case .display(let d, _) = $0.kind { return d == id }
                return false
            }
        case .preset(let id):
            return presetGroup.children.first {
                if case .preset(let p) = $0.kind { return p.id == id }
                return false
            }
        case .library(let cat):
            return libraryGroup.children.first {
                if case .library(let c) = $0.kind { return c == cat }
                return false
            }
        }
    }

    /// 用子类拦截鼠标点击，直接判断点到了哪一行。
    ///
    /// 只靠 target/action 不可靠：outline 的 action 仅在「选中行发生变化」时触发，
    /// 点「新建分类」这类「立即取消选中」的行时，回调可能根本不来。
    final class ClickOutlineView: NSOutlineView {
        var onClickRow: ((Int) -> Void)?
        /// 右键菜单：传入行号与视图，返回要弹出的菜单
        var onMenuRow: ((Int, NSView) -> NSMenu?)?

        /// 点空白处（没有落在任何行上）时通知外部
        var onBlankClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            let row = self.row(at: pt)
            if row >= 0 {
                onClickRow?(row)
            } else {
                onBlankClick?()
            }
            // 刻意不调 super.mouseDown：
            // 它会把选中集替换成「只有刚点的那行」，另外两组先丢高亮再被
            // syncOutlineSelection 补回来，中间闪一帧蓝框。
            // 选中状态完全由我们自己按三组记录计算并写入。
        }

        /// 右键：先选中该行，再弹出对应菜单。
        /// NSOutlineView 默认不提供行级右键，必须自己接。
        override func menu(for event: NSEvent) -> NSMenu? {
            let pt = convert(event.locationInWindow, from: nil)
            let row = self.row(at: pt)
            guard row >= 0 else { return nil }
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return onMenuRow?(row, self)
        }
    }

    @objc private func selectionChanged() {
        guard !suppressCallback else { return }
        // 只处理「本次新选中的那一行」，其它组的选中保持不变。
        // NSTableView 不告诉我们哪一行是刚点中的，所以取 selectedRowIndexes
        // 与三组已记录状态做差集，找出新增的那个。
        let rows = outline.selectedRowIndexes
        var changed: (row: Int, node: Node)?
        for r in rows {
            guard let node = outline.item(atRow: r) as? Node else { continue }
            if !isRecordedSelected(node) { changed = (r, node); break }
        }
        guard let (row, node) = changed else { return }

        switch node.kind {
        case .allDisplays:
            selectedDisplay = .allDisplays
            onSelect?(.allDisplays)
        case .display(let id, _):
            selectedDisplay = .display(id)
            onSelect?(.display(id))
        case .preset(let p):
            selectedPreset = .preset(p.id)
            onSelect?(.preset(p.id))
        case .savePreset, .newCategory:
            // 动作行：回调已由 onClickRow 触发，这里只撤掉选中。
            suppressCallback = true
            outline.deselectRow(row)
            suppressCallback = false
        case .library(let cat):
            selectedLibrary = .library(cat)
            onSelect?(.library(cat))
        case .group:
            break
        }
        // 原生点击会把选中集替换成「只有刚点的那一行」，
        // 这里立刻按三组记录重建，把另外两组的选中补回来。
        syncOutlineSelection()
    }

    /// 该节点当前是否已被记入某一组的选中状态
    private func isRecordedSelected(_ node: Node) -> Bool {
        switch node.kind {
        case .allDisplays:
            return selectedDisplay == .allDisplays
        case .display(let id, _):
            return selectedDisplay == .display(id)
        case .library(let cat):
            return selectedLibrary == .library(cat)
        case .preset(let p):
            return selectedPreset == .preset(p.id)
        default:
            return false
        }
    }

    private func screenIDOf(_ s: NSScreen) -> String {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let did = CGDirectDisplayID(n.uint32Value)
            if let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
                return CFUUIDCreateString(nil, cf) as String
            }
            return "display-\(did)"
        }
        return "screen-\(Int(s.frame.origin.x))-\(Int(s.frame.origin.y))"
    }

    private func screenTitleOf(_ s: NSScreen) -> String {
        let main = (s == NSScreen.main) ? L10n.t("common.mainScreen") : ""
        return "\(s.localizedName)\(main)"
    }
}

// MARK: - 数据源

extension SidebarNavigator: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        guard let node = item as? Node else { return 0 }
        return node.children.count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        guard let node = item as? Node else { return NSNull() }
        return node.children[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .group = node.kind { return true }
        return false
    }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .group = node.kind { return false }
        return true
    }

    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return 26 }
        switch node.kind {
        case .group: return 26
        case .preset: return 62      // 预设卡片要给叠图留高度
        default: return 30
        }
    }

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        switch node.kind {
        case .group(let which):
            let id = NSUserInterfaceItemIdentifier("groupCell")
            let label: NSTextField
            if let reused = ov.makeView(withIdentifier: id, owner: self) as? NSTextField {
                label = reused
            } else {
                label = NSTextField(labelWithString: "")
                label.identifier = id
                label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .tertiaryLabelColor
            }
            // macOS 照片的分组标题是小号灰字，不做大写转换
            switch which {
            case "library": label.stringValue = L10n.t("nav.library")
            case "preset":  label.stringValue = L10n.t("nav.presets")
            default:        label.stringValue = L10n.t("nav.displays")
            }
            return label

        case .preset(let p):
            return presetCell(p)

        case .display(let id, let title):
            return iconCell(symbol: "display", title: title, dim: false,
                            status: displayStatuses[id] ?? .empty)

        case .allDisplays:
            return iconCell(symbol: "rectangle.on.rectangle",
                            title: L10n.t("nav.allDisplays"), dim: false,
                            status: aggregateStatus)

        case .savePreset:
            return iconCell(symbol: "plus.circle",
                            title: L10n.t("preset.saveCurrent"), dim: true)

        case .library(let cat):
            let title = cat ?? L10n.t("nav.libraryAll")
            // 分类行显示该分类的封面缩略图，与照片 App 一致
            let cover = cat.flatMap { categoryCovers[$0] }
            return thumbCell(coverPath: cover, symbol: cat == nil ? "square.grid.2x2" : "folder",
                             title: title)

        case .newCategory:
            return iconCell(symbol: "folder.badge.plus",
                            title: L10n.t("category.new"), dim: true)
        }
    }

    /// 分类行：左侧是圆角方形的封面缩略图，没有封面时退回图标。
    /// 尺寸与 iconCell 的图标一致（16pt），保证两种行左缘对齐。
    private func thumbCell(coverPath: String?, symbol: String, title: String) -> NSView {
        let v = NSView()

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4.5
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(box)

        // 有封面就放图片，没有就先放图标占位。
        // .scaleAxesIndependently 会拉伸变形，这里用自绘的填充方式：
        // 等比放大到「铺满方块」再居中裁切，与照片 App 一致。
        let img = FillImageView()
        img.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(img)

        if let cover = coverPath {
            ThumbnailStore.shared.thumbnail(for: cover) { [weak img] cg in
                guard let img, let cg else { return }
                img.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        } else {
            // 空分类：画一个居中的图标，不铺满
            img.isIconMode = true
            img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            box.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 22),
            box.heightAnchor.constraint(equalToConstant: 22),
            img.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            img.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            img.topAnchor.constraint(equalTo: box.topAnchor),
            img.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    private func iconCell(symbol: String, title: String, dim: Bool,
                          status: DisplayStatus? = nil) -> NSView {
        let v = NSView()
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img.contentTintColor = dim ? .secondaryLabelColor : .labelColor
        img.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = dim ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(img)
        v.addSubview(label)

        var trailingAnchor = v.trailingAnchor
        var trailingConstant: CGFloat = -2

        // 状态点：贴在行右端的小圆点（显示器状态一目了然，
        // 替代了原来的底栏文字）
        if let status {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = status.color.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(dot)
            NSLayoutConstraint.activate([
                // 与分组标题行的折叠箭头同列：实测绿点比箭头偏左 9pt
                dot.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: 2),
                dot.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            trailingAnchor = dot.leadingAnchor
            trailingConstant = -8
        }

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 15),
            img.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: trailingConstant),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    /// 预设卡片：左侧叠几张缩略图，右侧名字 + 屏数
    private func presetCell(_ p: WallpaperPreset) -> NSView {
        let v = NSView()

        let stack = PresetThumbStack(frame: NSRect(x: 0, y: 0, width: 46, height: 40))
        stack.paths = Array(p.assignment.values.prefix(3))
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)

        let name = NSTextField(labelWithString: p.name)
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: L10n.t("nav.displayCount", p.displayCount))
        sub.font = NSFont.systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(name)
        v.addSubview(sub)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 46),
            stack.heightAnchor.constraint(equalToConstant: 40),

            name.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -2),
            name.topAnchor.constraint(equalTo: stack.topAnchor, constant: 3),

            sub.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            sub.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
        ])
        return v
    }
}
