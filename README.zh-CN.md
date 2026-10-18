# WallLocus

> **Remember every wallpaper's placement on every display.**

一个小巧、好改的 macOS 视频 / 图片壁纸工具。  
`Wall`（壁纸）+ `Locus`（位置、轨迹）——它记住每张壁纸在每块屏上的**位置轨迹**。

简体中文 · [English](README.md)

---

约 1700 行 Swift 的自包含 macOS 壁纸应用。无第三方依赖、无遥测、无需账号。只用 `swiftc` 构建——**不需要装完整 Xcode**。

## 它和别的壁纸软件有什么不同

**「显示器 × 壁纸」双维度记忆。**

每张壁纸在**每一块显示器**上都各自记住缩放模式、缩放倍率与水平/垂直偏移：

| 显示器      | 壁纸 A            | 壁纸 B           |
| -------- | --------------- | -------------- |
| 4K 外接显示器 | 150% · 偏移 −0.20 | 100% · 居中      |
| 笔记本内建屏   | 100% · 居中       | 73% · 偏移 +0.15 |
| 竖屏显示器    | 100% · 偏移 −0.55 | 100% · 居中      |

换显示器或换壁纸，之前的构图原样回来。多数壁纸应用最多给一个全局「填充/适应」开关；这里把构图当作**这一对组合**的属性。

## 功能

- **视频与静态图片**，用自己的文件
- **每块显示器独立设置壁纸**，支持热插拔
- **缩放模式**：填充（裁剪）/ 适应（留黑边）/ 拉伸
- **缩放** 30–300%、**水平/垂直位置** ±100%，滑块旁有可输入的数值框（两位小数）
- **全屏时自动暂停**：检测某块屏是否被全屏应用完整覆盖（覆盖率 ≥96%），只暂停那一块
- **电池供电时暂停**（可选）
- **菜单栏常驻**：关窗后 Dock 图标消失，菜单栏图标保留
- **占用极低**：视频走 AVPlayerLayer 硬件解码，图片走 ImageIO 降采样
- **视频兼容性检测**：对 macOS 解不了的视频给出提示，并可一键把 HEV1 标签改成 HVC1（无需重新编码）
- **中英双语界面**，跟随系统语言自动切换

## 实测占用

Apple 芯片 + macOS 26，三块显示器——两张静态图、一个 4K 视频：

| 指标                | 数值              |
| ----------------- | --------------- |
| 物理内存（`footprint`） | **约 96 MB**     |
| CPU（图片屏）          | **0.0 %**       |
| CPU（4K 视频屏）       | **1.6 – 3.4 %** |
| CPU（全屏应用打开时）      | **0.0 %**       |

> 注意：`ps` 的 RSS 显示高得多（约 190 MB），因为它把系统共享库的映射页也算进去了。要评估真实占用请用 `footprint -p <pid>` 或 `vmmap --summary`。

## 环境要求

- macOS **13.0** 及以上
- Apple 芯片或 Intel（用 `UNIVERSAL=1` 构建通用二进制）
- 只需 **Xcode Command Line Tools**（不需要完整 Xcode，也不需要 Homebrew）

## 构建

```bash
git clone https://github.com/ZEBRALD/walllocus.git
cd walllocus
./build.sh                 # 当前架构
UNIVERSAL=1 ./build.sh     # 通用二进制（arm64 + x86_64）
```

产物在 `build/WallLocus.app`。

## 安装

```bash
cp -R build/WallLocus.app /Applications/
xattr -dr com.apple.quarantine /Applications/WallLocus.app
open /Applications/WallLocus.app
```

本构建使用 **ad-hoc 签名且未公证**，首次启动会被 Gatekeeper 拦截。右键点应用选**打开**，或执行上面的 `xattr` 命令即可。

## 使用

1. 点 **添加文件…** 选择视频和/或图片。
2. 在**目标显示器**里选一块屏，或选「全部显示器」。
3. 在壁纸库里选中素材，点**设为该屏壁纸**。
4. 用滑块或直接输入数值调整**缩放模式 / 缩放 / 水平位置 / 垂直位置**。改动实时生效，并按「显示器 × 壁纸」分别记住。

菜单栏图标与软件主菜单（播放 / 显示器 / 缩放模式 / 设置）里也能完成所有操作。

## 架构说明

壁纸是一个处于桌面窗口层级的 `NSWindow`，里面承载 `AVPlayerLayer`（视频）或 `CALayer`（图片）。这让实现保持小巧、零依赖，但也带来两个有意的限制：

- **退出应用后壁纸消失**——它是应用自己的窗口，不是系统壁纸。
- **不支持锁屏壁纸**——锁屏由系统进程绘制，第三方窗口进不去。

要做这两点需要私有的 `WallpaperExtensionKit` 框架，超出小工具的范畴。

### 关于屏保

`.saver` 屏保在 **macOS 26 上不可用**：系统不再扫描 `~/Library/Screen Savers/`，
屏保面板只列出 ExtensionKit `.appex` 扩展（扩展点 `com.apple.screensaver`）。
连 Apple 自己内置的 `.saver` 也不再被注册。完整证据链见 [SCREENSAVER.md](SCREENSAVER.md)，
其中也保留了为将来做扩展方案而写的渲染代码。

## 配置

状态存在 bundle id `app.walllocus` 的 `UserDefaults` 中：

- `walllocus.state.v1` —— 素材库、每屏分配、每屏 × 每壁纸的调整量
- `pauseOnFullscreen`、`pauseOnBattery` —— 行为开关

开机自启用 `LaunchAgent`：`~/Library/LaunchAgents/app.walllocus.autostart.plist`（无授权弹窗，无需 Apple 开发者账号）。

## 常见问题

**视频黑屏。** 几乎可以确定是 HEV1 封装，macOS 只解 `hvc1`。应用会检测并给出一键修复，就地改写那四个字节（原文件保留为 `*.hev1bak.mp4`）。

**退出后壁纸没了。** 属预期行为，见「架构说明」。

**Dock 图标不见了。** 关窗后会主动隐藏，菜单栏图标仍在。点它选「打开 WallLocus」即可。

## 许可证

[MIT](LICENSE)。

## 致谢

使用 [DeepSeek Harness](https://github.com/deepseek-ai/dsh) 构建与迭代。
