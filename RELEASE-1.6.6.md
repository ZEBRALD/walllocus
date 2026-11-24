## 本次更新

> 说明：1.6.4 / 1.6.5 未单独发布，其内容已包含在本版中。

## 新功能：把壁纸拖到屏幕上就应用

按住图库里的任意壁纸，直接拖出窗口甩到某块屏幕上，松手即应用 —— **拖到哪块屏就应用到哪块屏**。

- 拖拽时每块屏幕中央浮现一个提示卡片，光标压在哪张上就高亮哪张
- 拖到卡片外松手不会误应用
- 拖到左栏的显示器行同样可以应用（更稳妥的路径）
- 拖到桌面则把文件复制出去
- 可在设置里关闭

## 左栏重新设计

- **显示器 / 壁纸库 / 预设三组各自独立选中** —— 可以同时选中「用这张图」和「投到那块屏」
- 选中态改为**亮灰圆角底 + 亮蓝文字**，不再是整行系统蓝
- 壁纸库分类显示该分类第一张图的**圆角方形缩略图**（与照片 App 一致，等比铺满并裁切）
- 「全部」改用堆叠图标
- 行高 33pt、缩略图 27pt、图标 22pt，列表更舒展
- 顶部留白收紧，与底部对称

## 新功能：自动刷新图库

以前只有添加文件后才刷新，现在切回 App、切换分类、切换显示器时都会比对**文件夹指纹**，磁盘真变了才重扫 —— 高频操作不会卡。

## 新功能：分类右键菜单

右键左栏的分类文件夹：**在访达中显示** / **移到废纸篓**（二次确认，可恢复）。

「全部」不对应实际文件夹，因此没有菜单。

## 图库

- 支持从图库把壁纸拖出
- 「正在使用」绿点固定贴在**图片本身的左上角**，不再随横竖图比例漂移

## 右栏

- 长文件名不再溢出：顶部标题**中间截断**，文件详情**按字符换行**

## 修复

- **从访达拖图片进 App 完全没反应** —— 窗口 wrapper 让拖放接收者不再是直接内容视图
- **拖拽到屏幕的提示卡片不出现**
- 拖入文件时提示浮层闪烁，偶尔导致拖放失败
- 绿加号只在部分区域显示（压在缩略图/预览图上时消失）
- 左栏信息框在未选中素材时是空的
- 多行同时高亮（选中底块未重绘）
- 新建分类时崩溃
- 「保存当前为预设」弹出两个命名窗口
- 选中素材时分辨率文字闪烁
- 分类切换时缩略图闪烁

---

## What's changed

> Note: 1.6.4 and 1.6.5 were never published separately; their contents are included here.

## New: drop a wallpaper onto a display to apply it

Pick up any wallpaper in the grid, drag it out of the window and release it over a display — that display takes it, and only that one.

- A hint card appears on each screen while dragging; the one under the pointer highlights
- Releasing outside a card does nothing
- Dropping on a display row in the sidebar works too
- Dropping on the desktop copies the file out
- Can be switched off in settings

## Sidebar, redrawn

- **Displays, library and presets each keep their own selection**
- Selection is a soft rounded fill with accent-coloured text, replacing the system blue
- Categories show a rounded square thumbnail of their first image, filled and clipped like Photos
- "All" uses the stacked-rectangle glyph
- Rows 33pt, thumbnails 27pt, glyphs 22pt
- The empty band above the first group trimmed to match the bottom

## New: the library refreshes on its own

A fingerprint of directory modification times is compared when the app becomes active, a category is chosen, or a display is picked. Only a real change triggers a rescan.

## New: category context menu

Show in Finder, or move the whole folder to the Trash behind a confirmation. "All" has no folder, so it has no menu.

## Library

- Wallpapers can be dragged out of the grid
- The green "in use" dot sits on the image's own corner and stops drifting with aspect ratio

## Detail pane

- Long file names stay inside the pane: the heading truncates in the middle, the file details wrap

## Fixes

- **Dropping files in stopped working entirely** — a wrapper view made the drop target stop being the content view
- **Screen drop targets for dragging wallpapers out disappeared**
- The import hint flickered and could fail a drop
- The green plus only appeared in some areas
- The sidebar info box was empty until an item was selected
- Multiple sidebar rows highlighted at once
- Crash when creating a category
- "Save as preset" opened two naming dialogs
- Resolution text flickered on selection
- Category thumbnails flickered when switching categories