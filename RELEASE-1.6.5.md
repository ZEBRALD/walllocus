## 本次更新

### 新功能：把壁纸拖到屏幕上就应用

按住图库里的任意壁纸，直接拖出窗口甩到某块屏幕上，松手即应用 —— 拖到哪块屏就应用到哪块屏。

- 拖拽时每块屏幕中央浮现一个提示卡片，光标压在哪张上就高亮哪张
- 拖到卡片外松手不会误应用
- 拖到左栏的显示器行同样可以应用（更稳妥的路径）
- 拖到桌面则可把文件复制出去
- 设置里可选提示方式：**所有屏幕都显示**（默认）或**只显示光标所在屏幕**

### 左栏重新设计

- **显示器 / 壁纸库 / 预设三组各自独立选中** —— 可以同时选中「用这张图」和「投到那块屏」
- 预设点击空白处取消选中，显示器与分类保持
- 壁纸库分类显示该分类第一张图的圆角缩略图（与照片 App 一致）
- 「全部」改用堆叠图标
- 选中态改为**亮灰圆角底 + 亮蓝文字**，不再是整行系统蓝
- 行高与图标尺寸调整，列表更舒展
- 顶部留白收紧，与底部对称

### 图库

- 支持从图库把壁纸拖出（新功能的基础）
- 「正在使用」绿点固定贴在**图片本身的左上角**，不再随横竖图比例漂移
- 缩略图放大到 27pt

### 右栏

- 长文件名不再溢出面板：顶部标题**中间截断**，文件详情**按字符换行**显示完整
- 拖入文件时的提示浮层不再闪烁（此前可能导致拖放失败）

### 修复

- 新建分类时崩溃
- 「保存当前为预设」弹出两个命名窗口
- 选中素材时分辨率文字闪烁
- 点击左栏时其余分组的选中框闪烁
- 拖入文件时提示浮层闪烁，偶尔导致拖放失败

---

## What's changed

### New: drop a wallpaper onto a screen to apply it

Pick up any wallpaper in the grid, drag it out of the window and release it over a display — that display takes it, and only that one.

- A hint card appears on each screen while dragging; the one under the pointer highlights
- Releasing outside a card does nothing, so a stray drop cannot repaint a monitor
- Dropping on a display row in the sidebar works too, and is the steadier path
- Dropping on the desktop copies the file out
- Settings choose whether hints appear on **every display** (default) or **only the one under the pointer**

### Sidebar, redrawn

- **Displays, library and presets each keep their own selection** — you can have "this picture" and "that display" chosen at once
- Clicking empty space clears the preset selection but leaves the other two alone
- Categories show a rounded thumbnail of the first image they contain, as Photos does
- "All" uses the stacked-rectangle glyph
- Selection is a soft rounded fill with accent-coloured text, replacing the full-width system blue
- Row heights and glyph sizes rebalanced for a less cramped list
- The empty band above the first group trimmed to match the bottom

### Library

- Wallpapers can be dragged out of the grid
- The green "in use" dot now sits on the image's own corner and stops drifting with aspect ratio
- Thumbnails enlarged to 27pt

### Detail pane

- Long file names stay inside the pane: the heading truncates in the middle, and the file details wrap to show the whole name
- The import hint no longer flickers (which could make a drop fail)

### Fixes

- Crash when creating a new category
- "Save as preset" opened two naming dialogs
- Resolution text flickered when selecting a wallpaper
- The other two sidebar groups' selection outlines flickered on every click
- The import hint flickered while dragging files in, occasionally failing the drop