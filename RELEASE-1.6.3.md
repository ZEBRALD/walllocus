## 本次更新

### 界面细节
- 窗口四角改为 22pt 圆角，与左右栏面板的弧度对齐
- 左右栏与窗口边缘的间距从 12pt 收紧到 8pt
- 中栏左右边距与左右栏统一，五列网格首尾两列不再贴边
- 三栏滚动条现在都停在各自面板右缘 3pt 处，位置一致
- 左栏分组顺序默认为 **显示器 → 壁纸库 → 预设**

### 性能
- 搜索改为 200ms 去抖，连续输入只在停顿后重排一次网格
- 分类列表加缓存，不再每次刷新都重新扫描磁盘
- 网格内容比对从全量路径比较改为数量加首尾抽样
- 预览图缓存从 48MB 收紧到 12MB（与其 6 张上限相符）

### 修复
- **「移到废纸篓」现在真的会把文件移入废纸篓**，此前只改了按钮文案，文件仍留在文件夹里
- 图库空白处右键菜单恢复（此前钩子已声明但从未接线）

---

## What's changed

### Interface details
- Window corners are now 22pt, matching the side panels' curvature
- Side panes sit 8pt from the window edge, down from 12pt
- The grid's side margins now match the panes, so the first and last columns no longer
  press against the edges
- All three scrollbars come to rest 3pt from their panel's right edge
- Sidebar groups default to **Displays → Library → Presets**

### Performance
- Search is debounced by 200ms, so a burst of typing triggers one grid rebuild
- The category list is cached instead of re-reading the folder on every refresh
- The grid's content check compares counts and endpoints rather than two full path arrays
- Preview cache cut from 48MB to 12MB, matching its six-image limit

### Fixes
- **"Move to Trash" now actually moves the file to the Trash**; previously only the label
  changed and the file stayed in the folder
- The grid's blank-area context menu is wired up again (the hook existed but was never assigned)