import Foundation

// ============================================================
//  SharedConfig — 主 App 与屏保之间的配置契约
//
//  屏保运行在独立的沙盒进程 legacyScreenSaver 里，无法访问主 App 的内存，
//  因此通过 UserDefaults suite 传递「当前该播什么、怎么摆」。
//
//  写入方：主 App（WallLocus）
//  读取方：屏保（WallLocusSaver）
//  屏保只读不写，避免沙盒写权限问题。
// ============================================================

enum SharedConfig {
    /// 共享域。两侧都用这个名字创建 UserDefaults。
    static let suiteName = "app.walllocus.shared"

    /// 主 App 自己的域，作为回退读取源
    static let hostDomain = "app.walllocus"

    enum Key {
        /// 要播放的素材绝对路径
        static let mediaPath = "screensaver.mediaPath"
        /// 缩放模式（ScaleMode.rawValue）
        static let scaleMode = "screensaver.scaleMode"
        /// 缩放倍率
        static let zoom = "screensaver.zoom"
        /// 水平偏移
        static let offsetX = "screensaver.offsetX"
        /// 垂直偏移
        static let offsetY = "screensaver.offsetY"
        /// 是否静音
        static let muted = "screensaver.muted"
        /// 配置写入时间（用于调试与「是否过旧」判断）
        static let updatedAt = "screensaver.updatedAt"
    }

    /// 屏保要播的内容
    struct Snapshot: Equatable {
        var mediaPath: String
        var adjustment: Adjustment
        var muted: Bool

        init(mediaPath: String, adjustment: Adjustment = .default, muted: Bool = true) {
            self.mediaPath = mediaPath
            self.adjustment = adjustment
            self.muted = muted
        }
    }

    // MARK: - 写（主 App 调用）

    static func save(_ snapshot: Snapshot) {
        guard let d = UserDefaults(suiteName: suiteName) else { return }
        d.set(snapshot.mediaPath, forKey: Key.mediaPath)
        d.set(snapshot.adjustment.mode.rawValue, forKey: Key.scaleMode)
        d.set(snapshot.adjustment.zoom, forKey: Key.zoom)
        d.set(snapshot.adjustment.offsetX, forKey: Key.offsetX)
        d.set(snapshot.adjustment.offsetY, forKey: Key.offsetY)
        d.set(snapshot.muted, forKey: Key.muted)
        d.set(Date().timeIntervalSince1970, forKey: Key.updatedAt)
    }

    // MARK: - 读（屏保调用）

    /// 读取当前配置。先看共享域，没有则回退主 App 域，最后返回 nil。
    static func load() -> Snapshot? {
        if let s = read(from: UserDefaults(suiteName: suiteName)) { return s }
        if let s = read(from: UserDefaults(suiteName: hostDomain)) { return s }
        return nil
    }

    private static func read(from d: UserDefaults?) -> Snapshot? {
        guard let d else { return nil }
        guard let path = d.string(forKey: Key.mediaPath), !path.isEmpty else { return nil }
        // 文件可能已被移动或删除，这里只回传路径，由调用方决定如何兜底
        let rawMode = d.string(forKey: Key.scaleMode) ?? ScaleMode.fill.rawValue
        var adj = Adjustment()
        adj.mode = ScaleMode(rawValue: rawMode) ?? .fill

        // 倍率与偏移可能从未写过，用 object(forKey:) 判断存在性再取值
        if d.object(forKey: Key.zoom) != nil { adj.zoom = d.double(forKey: Key.zoom) }
        if d.object(forKey: Key.offsetX) != nil { adj.offsetX = d.double(forKey: Key.offsetX) }
        if d.object(forKey: Key.offsetY) != nil { adj.offsetY = d.double(forKey: Key.offsetY) }

        let muted = d.object(forKey: Key.muted) == nil ? true : d.bool(forKey: Key.muted)
        return Snapshot(mediaPath: path, adjustment: adj, muted: muted)
    }

    /// 清空配置（卸载屏保时调用）
    static func clear() {
        guard let d = UserDefaults(suiteName: suiteName) else { return }
        for k in [Key.mediaPath, Key.scaleMode, Key.zoom, Key.offsetX,
                  Key.offsetY, Key.muted, Key.updatedAt] {
            d.removeObject(forKey: k)
        }
    }

    // MARK: - 安装状态

    /// 屏保在用户目录下的标准安装路径
    static var installedSaverURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Screen Savers/WallLocus.saver")
    }

    static var isSaverInstalled: Bool {
        FileManager.default.fileExists(atPath: installedSaverURL.path)
    }
}
