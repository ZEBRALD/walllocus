import AppKit

// ============================================================
//  DropCoordinator — 管理"拖拽壁纸到屏幕"的整个会话
//
//  职责：
//   1. 拖拽开始时为每块屏幕创建 overlay，结束时全部销毁
//   2. 拖拽期间以 30Hz 轮询鼠标位置，实时更新哪块屏处于命中态
//   3. 松手时把素材应用到命中的那块屏（P5）
//
//  为什么用轮询而不是纯 NSDraggingDestination：
//   overlay 的 draggingEntered 有系统延迟，且光标停在屏幕之间时
//   两边都收不到事件；轮询能保证高亮始终跟手。
// ============================================================

final class DropCoordinator {

    static let shared = DropCoordinator()

    /// 拖拽会话结束回调（路径 + 命中的 NSScreen），由 AppDelegate 接
    var onApply: ((String, NSScreen) -> Void)?

    private var overlays: [ScreenDropOverlay] = []
    private var timer: Timer?
    private var draggedPath: String?
    private var targetedScreen: NSScreen?

    private init() {}

    var isActive: Bool { !overlays.isEmpty }

    // MARK: - 会话控制

    func begin(path: String) {
        // 防御：上一次会话没清干净就重建
        if isActive { end() }

        draggedPath = path
        targetedScreen = nil

        for screen in NSScreen.screens {
            let ov = ScreenDropOverlay(screen: screen)
            let name = screen.localizedName
            let size = screen.frame.size
            let res = String(format: "%.0f × %.0f", size.width, size.height)
            // 初始一律不高亮：高亮只代表「光标正压在这张卡片上」，
            // 拖起瞬间光标还在应用窗口里，没有瞄准任何屏幕。
            ov.configure(screenName: name, resolution: res, targeted: false)
            ov.onDrop = { [weak self] path in
                guard let self else { return }
                self.onApply?(path, screen)
                self.end()
            }
            overlays.append(ov)
        }

        // 先不显示：要等光标拖出应用窗口才铺提示，
        // 否则铺满整屏的 overlay 会抢走左栏/图库的拖拽事件。
        startPolling()
    }

    func end() {
        timer?.invalidate()
        timer = nil
        let snapshot = overlays
        overlays.removeAll()
        draggedPath = nil
        targetedScreen = nil
        for ov in snapshot { ov.fadeOut() }
    }

    // MARK: - 实时高亮

    /// 某块屏上卡片所占的矩形（与 ScreenDropOverlay 的窗口位置一致）
    static func cardRect(on screen: NSScreen) -> NSRect {
        let c = ScreenDropOverlay.cardCenter(on: screen)
        let w = ScreenDropOverlay.cardWidth
        let h = ScreenDropOverlay.cardHeight
        return NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// 隐藏所有 overlay（光标回到应用内时）
    private func hideAll() {
        for ov in overlays where ov.isVisible { ov.fadeOut() }
    }

    /// 确保 overlay 已显示（光标离开应用后）
    private func ensureVisible() {
        // 所有屏幕的提示卡片始终显示，只切换高亮
    }

    /// 主窗口的屏幕区域（用来判断光标是否还在应用内）
    private func appWindowFrame() -> NSRect? {
        NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })?.frame
    }

    private func startPolling() {
        // 关键：必须用 .common mode，否则拖拽期间（eventTracking）不触发
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let p = NSEvent.mouseLocation

        // overlay 只有卡片大小、且只放在各屏正中，
        // 不会挡住左栏或桌面，所以拖拽一开始就可以显示。
        ensureVisible()

        // 两个判定分开：
        //   screenHit —— 光标在哪块屏（.targeted 用它决定显示哪块屏的卡片）
        //   cardHit   —— 光标是否正压在卡片上（只有它才算「瞄准」，松手才会应用）
        var screenHit: NSScreen?
        var cardHit: NSScreen?
        for screen in NSScreen.screens {
            if screenHit == nil, NSMouseInRect(p, screen.frame, false) {
                screenHit = screen
            }
            if cardHit == nil, NSMouseInRect(p, Self.cardRect(on: screen), false) {
                cardHit = screen
            }
        }
        let hit = cardHit

        guard hit !== targetedScreen else { return }
        targetedScreen = hit

        for ov in overlays {
            let targeted = (ov.screenRef === hit)
            let size = ov.screenRef.frame.size
            let res = String(format: "%.0f × %.0f", size.width, size.height)
            ov.configure(screenName: ov.screenRef.localizedName,
                         resolution: res,
                         targeted: targeted)

            // 所有屏幕的提示卡片始终显示，只切换高亮
        }
    }
}
