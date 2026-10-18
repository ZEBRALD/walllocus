# 屏保（Screen Saver）调研与结论

> 结论先行：**macOS 26 不支持传统 `.saver` 屏保**，本项目的屏保方案在验证阶段被否决。
> 此文档记录完整证据与代码留存，避免以后重复踩坑。

---

## 一、结论

| 问题 | 答案 |
|---|---|
| 能否用传统 `.saver` 做屏保？ | ❌ **不能**，macOS 26 已不再扫描该目录 |
| 代码本身有问题吗？ | ❌ 没有，bundle 可正常加载、类可实例化 |
| 要怎样才能做屏保？ | 需要 ExtensionKit `.appex`（扩展点 `com.apple.screensaver`） |
| 工作量？ | 与 wallpaper extension 同量级（数天到一两周） |

---

## 二、决定性证据（本机 macOS 26.6.2 实测）

把构建好的 `WallLocus.saver` 放进 `~/Library/Screen Savers/` 后，系统屏保面板的
「自定义」列表里**看不到它**。逐层排查得到五条互相印证的证据：

### 1. LaunchServices 拒绝扫描

```bash
$ lsregister -f ~/Library/Screen\ Savers/WallLocus.saver
failed to scan ...: -10811
```

`-10811` = bundle 格式不被接受。

### 2. 连 Apple 自己的 .saver 也一样

```bash
$ lsregister -f "/System/Library/Screen Savers/FloatingMessage.saver"
failed to scan ...: -10811
```

**这条最关键**——说明不是我们的 bundle 有问题，而是整个机制变了。

### 3. 所有可用屏保都是 .appex

```bash
$ pluginkit -m -p com.apple.screensaver
com.apple.ScreenSaver.Drift(1.0)
com.apple.ScreenSaver.Ventura(1.0)
com.apple.ScreenSaver.Monterey(1.0)
com.apple.ScreenSaver.Hello(1.0)
com.apple.WordOfTheDay(1.0)
com.apple.ScreenSaver.iLife-Slideshow-Extension(1.0)
...
```

路径全在 `/System/Library/ExtensionKit/Extensions/*.appex`。

### 4. legacyScreenSaver 本身就是扩展

`/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex` 的
Info.plist：

```xml
CFBundlePackageType      XPC!
NSExtensionPointIdentifier   com.apple.screensaver
NSExtensionPrincipalClass    LegacyController
```

它是**兼容宿主**，不是扫描器。

### 5. 系统目录里的 .saver 只是遗留资源

```bash
$ pluginkit -m | grep -c "FloatingMessage"
0
```

`/System/Library/Screen Savers/` 下那 2 个 `.saver`（FloatingMessage、Random）
在 pluginkit 里**匹配数为 0**——它们被动保留，不再被枚举。

---

## 三、代码本身是好的

为排除「是我写错了」，我写了验证器动态加载 bundle：

```
bundle:       .../WallLocus.saver
identifier:   app.walllocus.saver
loaded:       true
principalClass: WallLocusSaverView
superclass:   ScreenSaverView        ← 继承链正确
```

**结论：`.saver` 的构建方式、Info.plist 字段、类继承全对，是系统不再扫描那个目录。**

---

## 四、留存的代码

| 文件 | 作用 | 可复用性 |
|---|---|---|
| `Rendering.swift` | 缩放/位置布局纯函数 | ✅ 主 App 正在用 |
| `SharedConfig.swift` | 主 App ↔ 扩展的配置契约 | ✅ 任何扩展方案可用 |
| `ScreenSaver/WallLocusSaverView.swift` | 屏保渲染视图 | ✅ 逻辑可直接搬进 `.appex` |
| `ScreenSaver/Info.plist` | `.saver` 元信息 | ⚠️ 仅供参考 |

`build.sh` 中已注释掉 saver 构建段，避免产出无用产物。

---

## 五、如果将来要做屏保

正确路径是 **ExtensionKit 扩展**，不是 `.saver`：

```
WallLocusScreenSaver.appex/
└── Contents/
    ├── Info.plist          # 需含 NSExtension 声明
    ├── MacOS/
    └── Resources/
```

Info.plist 关键字段：

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.screensaver</string>
    <key>NSExtensionPrincipalClass</key>
    <string>你的ViewController子类</string>
</dict>
```

> 注意：`legacyScreenSaver.appex` 用的是 `NSExtensionPrincipalClass = LegacyController`，
> 宿主类是 `LegacyViewController`。新式扩展可能需要不同基类，需实测确认。

**建议下次先做最小验证**：写一个空 appex，确认 `pluginkit -m | grep 你的bundle` 能看到它，
再投入实现。这次就是跳过了这步才做到最后才发现不通。

---

## 六、参考

- 本次验证全程记录见 `research/screensaver-implementation-plan-2026-10.md`
- 相关方案对比见 `research/lockscreen-routeA-cost-analysis-2026-10.md`
- Apple：`legacyScreenSaver` 的扩展声明（本机实测）
