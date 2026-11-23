## 本次更新

### 修复：拖入图片与拖拽应用壁纸

上一版引入窗口 wrapper 后，**从访达拖图片进 App 会完全没反应**，拖拽壁纸到屏幕的提示卡片也消失了。

两处都是同一个原因：拖放接收必须挂在窗口的直接内容视图上，wrapper 把 `DropZoneView` 降成了子视图。现已恢复直接挂载，窗口尺寸限制改用 `contentMinSize/MaxSize` 表达。

同时修掉了几个拖拽相关的老问题：

- **提示浮层不再闪烁**：光标掠过子视图时 AppKit 会发 `draggingExited`，之前据此隐藏浮层，导致反复显隐。现在只在放置完成、取消、或轮询确认鼠标真的离开窗口时才收起
- **绿加号处处可见**：之前压在缩略图、预览图上时加号消失（系统问的是那些不接收文件的视图）。拖拽期间会在最上层铺一层接收面，任何位置都返回一致的接受状态（带连续采样，避免单次读取失败导致中途失效）
- **拖拽绕圈久了不再偶发失效**

### 新功能：自动刷新图库

以前只有添加文件后才刷新，现在：

| 触发时机 | 行为 |
| --- | --- |
| 切回 App（从访达回来） | 比对文件夹指纹 |
| 切换壁纸库分类 | 同上 |
| 切换显示器 | 同上 |
| 启动 | 全量扫描一次 |

用**目录修改时间指纹**判断，磁盘真变了才重扫 —— 切分类这类高频操作不会卡。

### 新功能：分类右键菜单

右键左栏的分类文件夹：

- **在访达中显示**
- **移到废纸篓**（二次确认，整个文件夹可恢复）

「全部」不对应实际文件夹，因此没有菜单。

### 修复：左栏信息框

以前**没选中素材时它是空的**，只在选中后才显示显示器信息。但它是显示器状态（作用范围、分辨率、正在使用哪张壁纸），不该依赖素材选中。现已在两种路径下都正确显示。

### 界面

- 预设的选中状态：点右栏（应用预设等操作）时保留，点中栏或左栏其它位置时清除
- 修复左栏多行同时高亮（选中底块未重绘）
- 分类切换时缩略图不再闪烁（缓存命中改为同步设图 + 结构未变时跳过重建）

---

## What's changed

### Fixed: dropped files and drag-to-apply

The previous release introduced a wrapper view to fix window resizing, which **broke dropping files in entirely** and made the screen-target cards disappear.

Both had one cause: AppKit only delivers drops to a window's direct content view, and the wrapper demoted `DropZoneView` to a subview. It is the content view again, with the size limits expressed through `contentMinSize/MaxSize`.

Several older drag problems went with it:

- **The import hint stopped flickering.** AppKit sends `draggingExited` when the pointer moves over a subview even though it is still inside the window; hiding on that event made the hint blink. It now retires only on a completed drop, on cancel, or when a poll confirms the pointer really left
- **The green plus is visible everywhere.** It used to vanish over thumbnails and the preview because the system asked those views, which do not accept files. A full-window sink sits on top during a drag so every position answers the same way
- **Long drags no longer lose the cursor feedback**

### New: the library refreshes on its own

It used to refresh only after adding files. Now:

| Trigger | Behaviour |
| --- | --- |
| Returning to the app | Compare the folder fingerprint |
| Switching category | Same |
| Switching display | Same |
| Launch | One full scan |

A fingerprint of directory modification times decides whether a rescan is needed, so switching categories stays instant.

### New: category context menu

Right-click a category in the sidebar:

- **Show in Finder**
- **Move to Trash**, behind a confirmation — the whole folder, restorable

"All" has no folder behind it, so it has no menu.

### Fixed: the sidebar info box

It showed nothing until a wallpaper was selected. But it reports display state — scope, resolution, and which wallpaper that display is using — so it no longer depends on an item being selected.

### Interface

- Preset selection: kept when clicking the detail pane (where presets are applied), cleared when clicking the grid or elsewhere in the sidebar
- Fixed multiple sidebar rows appearing highlighted at once, by invalidating the row when its selection changes
- Category thumbnails no longer flicker when switching categories