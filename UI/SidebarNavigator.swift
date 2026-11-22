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
    private var presets: [WallpaperPreset] = []
    private var screens: [NSScreen] = []
    private var categories: [String] = []
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
    private let libraryGroup = Node(.group("library"))
    private let presetGroup = Node(.group("preset"))
    private let displayGroup = Node(.group("display"))
    private lazy var roots: [Node] = [libraryGroup, presetGroup, displayGroup]

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

        // 左导航：三块区域里最「实」的一层，作为视觉基座。
        // 用 sidebar 材质（系统侧栏观感）+ 略重的 tint 拉开层次。
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        // 先在玻璃下面垫一层不透明底色：
        // 这样无论采样模式如何，都不可能透出桌面。
        // 光靠 blendingMode 不可靠 —— DropZoneView 覆写了 addSubview 并
        // 把拖拽 overlay 提到最前，玻璃在那一层之上的采样结果不稳定。
        let backing = NSView()
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor(srgbRed: 0.129, green: 0.133,
                                                 blue: 0.145, alpha: 1.0).cgColor
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 采样这层垫底色（不是窗口背景，也不是桌面）
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        // 玻璃层也要裁圆，否则它会在父视图圆角外露出直角
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        addSubview(blur, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // 与右栏一致的 liquid glass 描边（侧栏的玻璃是自建的，不过 addGlass）
        let rim = GlassRimView()
        rim.cornerRadius = 16
        rim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rim)
        NSLayoutConstraint.activate([
            rim.topAnchor.constraint(equalTo: topAnchor),
            rim.leadingAnchor.constraint(equalTo: leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: trailingAnchor),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tint = NSView()
        tint.wantsLayer = true
        // 压暗：.sidebar 材质在深色底上会偏亮（它是为浅色系统 UI 设计的），
        // 加一层更重的黑色 tint 把它拉回到与底色同色系
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: blur.topAnchor),
            tint.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
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
                self.outline.deselectAll(nil)
                self.onNewCategory?()
            case .savePreset:
                self.outline.deselectAll(nil)
                self.onSavePreset?()
            default:
                break        // 可选中的行交给 selectionChanged
            }
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
            // 左右各缩进 8：给选中条留出与面板边缘的呼吸
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: 数据

    func reload(presets: [WallpaperPreset],
                screens: [NSScreen],
                categories: [String] = [],
                statuses: [String: DisplayStatus] = [:],
                aggregate: DisplayStatus = .empty,
                selection: SidebarSelection?) {
        self.presets = presets
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
        guard let selection else {
            suppressCallback = true
            outline.deselectAll(nil)
            suppressCallback = false
            return
        }
        if let node = findNode(for: selection) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                suppressCallback = !notify
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                suppressCallback = false
            }
        }
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

        override func mouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            let row = self.row(at: pt)
            if row >= 0 {
                onClickRow?(row)
            }
            super.mouseDown(with: event)
        }
    }

    @objc private func selectionChanged() {
        guard !suppressCallback else { return }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }

        switch node.kind {
        case .allDisplays:
            onSelect?(.allDisplays)
        case .display(let id, _):
            onSelect?(.display(id))
        case .preset(let p):
            onSelect?(.preset(p.id))
        case .savePreset:
            // 「保存当前为预设」不是可停留的选中项，回到之前的状态
            outline.deselectRow(row)
            onSavePreset?()
        case .library(let cat):
            onSelect?(.library(cat))
        case .newCategory:
            outline.deselectRow(row)
            onNewCategory?()
        case .group:
            break
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
            return iconCell(symbol: cat == nil ? "square.grid.2x2" : "folder",
                            title: title, dim: false)

        case .newCategory:
            return iconCell(symbol: "folder.badge.plus",
                            title: L10n.t("category.new"), dim: true)
        }
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
        label.lineBreakMode = .byTruncatingMiddle
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
                dot.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
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
