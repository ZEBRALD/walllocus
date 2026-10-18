import CoreGraphics
import Foundation

// ============================================================
//  Rendering — 主 App 与屏保共用的画面布局计算
//  纯函数，不依赖 AppKit / UIKit，两边都能链接
// ============================================================

/// 画面缩放的三种模式
enum ScaleMode: String, Codable, CaseIterable {
    case fill, fit, stretch
}

/// 一个素材在**某一块显示器**上的画面调整量
struct Adjustment: Codable, Equatable {
    var mode: ScaleMode = .fill
    var zoom: Double = 1.0
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0

    static let `default` = Adjustment()
}

enum Rendering {
    /// 计算媒体图层在容器里的 frame。
    ///
    /// - Parameters:
    ///   - bounds:   容器尺寸（屏幕或窗口的可绘制区域）
    ///   - mediaSize: 素材原始像素尺寸
    ///   - adjustment: 缩放模式 / 倍率 / 偏移
    /// - Returns: 图层应占的矩形；尺寸异常时返回 bounds 本身
    static func layerFrame(bounds: CGRect,
                           mediaSize: CGSize,
                           adjustment: Adjustment) -> CGRect {
        guard bounds.width > 1, bounds.height > 1 else { return bounds }
        guard mediaSize.width > 1, mediaSize.height > 1 else { return bounds }

        var base: CGSize
        switch adjustment.mode {
        case .stretch:
            base = bounds.size
        case .fill:
            let s = max(bounds.width / mediaSize.width, bounds.height / mediaSize.height)
            base = CGSize(width: mediaSize.width * s, height: mediaSize.height * s)
        case .fit:
            let s = min(bounds.width / mediaSize.width, bounds.height / mediaSize.height)
            base = CGSize(width: mediaSize.width * s, height: mediaSize.height * s)
        }

        let z = CGFloat(max(0.05, adjustment.zoom))
        let w = base.width * z
        let h = base.height * z
        let cx = bounds.midX + CGFloat(adjustment.offsetX) * bounds.width * 0.5
        let cy = bounds.midY + CGFloat(adjustment.offsetY) * bounds.height * 0.5
        return CGRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h)
    }

    /// 判断一个素材能否被当作图片处理（按扩展名）
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "webp", "gif"
    ]

    static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
