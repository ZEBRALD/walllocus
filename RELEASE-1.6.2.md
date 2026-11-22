## 本次更新

### 全新三栏界面
界面参照 macOS 照片 App 重做：左侧导航、中间图库、右侧详情。三栏都铺满 liquid glass，
整个窗口共享同一块玻璃底，拖动左右栏边缘即可调整宽度，宽度会被记住。

### 左栏
- 默认顺序改为 **显示器 → 壁纸库 → 预设**，可在设置里切换全部六种排列
- 底部新增信息区，显示当前选中显示器的分辨率与正在使用的壁纸
- 显示器状态点与分组折叠箭头对齐

### 图库
- 缩略图按实际显示尺寸解码，Retina 屏上不再发糊
- 缩略图圆角改为按图片实际比例裁切，竖图横图都不再有方块边
- 增加「在网格中显示文件名」开关
- 支持按**文件名**或**修改时间**排序，升降序可选
- 右键空白处可**立即刷新**、添加文件、在访达中显示壁纸文件夹

### 详情栏
- 预览图上方显示文件名，预览图跟随栏宽
- 分隔线与滑块行随栏宽自适应
- 移除名称编辑框，改名请直接在访达里操作
- 操作按钮按影响范围从小到大重排
- 「从库移除」改为**移到废纸篓**，文件真正进入废纸篓（可恢复）

### 预设
- 右键预设可选择**应用 / 重命名 / 删除**
- 此前删除入口在界面上无法触达

### 顶栏
- 搜索框宽度跟随详情栏，文字垂直居中
- 新增 **+** 按钮用于添加壁纸，右栏里的旧按钮已移除

### 修复
- 窗口此前只能改高度、无法调整宽度
- 拖动栏边缘时窗口会被撑大，而不是中栏收窄
- 拖拽浮层吞掉鼠标事件，导致图库无法滚动
- 选中素材后预览区空白、左下角显示「无」

---

## What's changed

### New three-pane layout
Rebuilt around the macOS Photos structure: navigation, grid, and details. All three panes share
one liquid-glass base, and dragging either pane's edge resizes it — widths persist across launches.

### Sidebar
- Default order is now **Displays → Library → Presets**, with all six permutations available in settings
- A summary box at the bottom shows the selected display's resolution and current wallpaper
- Status dots line up with the group disclosure arrows

### Library
- Thumbnails decode at their real display size, so they stay sharp on Retina screens
- Rounded corners are clipped to each image's own aspect ratio — no more square edges on portrait images
- Added a "show file names in grid" toggle
- Sort by **file name** or **date modified**, ascending or descending
- Right-click empty space to refresh, add files, or reveal the folder in Finder

### Detail pane
- The file name sits above the preview, and the preview follows the pane width
- Separators and slider rows stretch with the pane
- The rename field is gone — rename in Finder instead
- Actions are ordered from the narrowest to the broadest effect
- "Remove from library" now **moves the file to the Trash**, where it can be recovered

### Presets
- Right-click a preset for **load / rename / delete**
- Deleting a preset was previously unreachable from the UI

### Toolbar
- The search field tracks the detail pane's width, with vertically centred text
- A **+** button adds wallpapers; the old button in the detail pane is gone

### Fixes
- The window could be resized vertically but not horizontally
- Dragging a pane edge grew the window instead of narrowing the grid
- The drag overlay swallowed mouse events, so the grid would not scroll
- Selecting a wallpaper left the preview blank and the scope label empty