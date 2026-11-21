import AppKit

// ============================================================
//  SidebarNavigator — 左侧导航：预设 + 显示器
//
//  两者放在同一个 NSOutlineView 里，因为它们是同一类东西：
//  「一份配置的应用范围」。预设是跨屏的一整套，显示器是单屏。
//  选中谁，中间网格就显示它当前在用哪张，右侧就调它的参数。
//  单一 selection 天然保证了两者互斥。
// ============================================================

enum SidebarSelection: Equatable {
    case preset(String)      // WallpaperPreset.id
    case display(String)     // 显示器 UUID；空串代表"全部显示器"
    case allDisplays
}

final class SidebarNavigator: NSView {

    /// 选中项变化
    var onSelect: ((SidebarSelection) -> Void)?
    /// 点「保存当前为预设」
    var onSavePreset: (() -> Void)?
    /// 预设右键菜单（传入 preset id）
    var onPresetMenu: ((String, NSView) -> NSMenu?)?

    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private var presets: [WallpaperPreset] = []
    private var screens: [NSScreen] = []
    private var suppressCallback = false

    /// 顶层节点：预设分组、显示器分组
    private final class Node {
        enum Kind {
            case group(String)
            case preset(WallpaperPreset)
            case display(String, String)   // (id, 标题)
            case allDisplays
            case savePreset
        }
        let kind: Kind
        var children: [Node] = []
        init(_ kind: Kind) { self.kind = kind }
    }
    private let presetGroup = Node(.group("preset"))
    private let displayGroup = Node(.group("display"))
    private lazy var roots: [Node] = [presetGroup, displayGroup]

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
        layer?.backgroundColor = NSColor.clear.cgColor

        // 左导航：三块区域里最「实」的一层，作为视觉基座。
        // 用 sidebar 材质（系统侧栏观感）+ 略重的 tint 拉开层次。
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.10).cgColor
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
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(selectionChanged)
        outline.autoresizesOutlineColumn = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: 数据

    func reload(presets: [WallpaperPreset],
                screens: [NSScreen],
                selection: SidebarSelection?) {
        self.presets = presets
        self.screens = screens

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
        case .group: return 22
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
                label.textColor = .secondaryLabelColor
            }
            label.stringValue = which == "preset"
                ? L10n.t("nav.presets").uppercased()
                : L10n.t("nav.displays").uppercased()
            return label

        case .preset(let p):
            return presetCell(p)

        case .display(_, let title):
            return iconCell(symbol: "display", title: title, dim: false)

        case .allDisplays:
            return iconCell(symbol: "rectangle.on.rectangle",
                            title: L10n.t("nav.allDisplays"), dim: false)

        case .savePreset:
            return iconCell(symbol: "plus.circle",
                            title: L10n.t("preset.saveCurrent"), dim: true)
        }
    }

    private func iconCell(symbol: String, title: String, dim: Bool) -> NSView {
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
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 15),
            img.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -2),
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
