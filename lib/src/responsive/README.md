# 横屏适配总索引（Landscape Gate）

移动端「竖屏 / 横屏」两套 UI 在**架构上完全分开**。本文档是把所有零散的横屏适配
收拢在一起的唯一索引 —— 任何页面要接横屏、任何 AI 想改横屏，先读这里定位。

## 核心原则

1. **断点单一来源**：是否横屏只由 `isLandscapeProvider` 判定
   （宽松式断点：`宽 >= 高 × 1.05`，含大屏 / 平板）。不要在任何页面里
   自己写 `MediaQuery.of(context).size.width >= ...`。
2. **页面顶层统一接 `LandscapeGate`**：竖屏子树与横屏子树在结构上完全分开，
   各自独立 widget / 方法。改横屏只动 `landscape` 分支，竖屏不受影响。
3. **横屏 = 独立一套 UI**，不是对竖屏做微调。布局、控件、状态各自独立。

## 架构分层

```
OS 传感器 / 壳层观察
        │  唯一写入点
        ▼
shell.dart  ── isLandscapeProvider（Bool StateProvider，每帧回写实际宽高比）
        │  ref.watch(isLandscapeProvider)
        ▼
landscape.dart ── LandscapeGate（portrait / landscape 两子树切换）+ useLandscape(ref)
        │
        ├── 页面顶层：SettingsPage / MinePage / PlayerPage
        └── 后续新页面：同样顶层套一层 LandscapeGate 即可
```

- **观察点（谁感知方向）**：`lib/src/navigation/shell.dart`
  - 定义并每帧回写 `isLandscapeProvider`（值不变则不通知）。
  - 横屏时导航自动切为**左侧边栏**形态（`LandscapeSideRail` + 右侧主 tab），
    音乐库入口（本地/收藏/最近/歌单）点选后**右侧内嵌**显示，不 push 二级页（IndexedStack 保持状态）。
  - 横屏右侧容器顶部统一渲染**全局顶栏**（`LandscapeGlobalTopBar`）：
    搜索框 + 皮肤 + 设置，首页 / 我的等右侧页面不再各自渲染顶栏，全部继承这一根。
  - **账号与安全**横屏由「我的」快捷卡内嵌打开（`landscapeAccountOpenProvider`），
    以 `Positioned.fill` 盖住右侧容器（含全局顶栏），复用 `AccountPage.embedded` 自带顶栏返回，不开二级路由。
  - 横屏沉浸式全屏：隐藏系统状态栏 / 导航条，铺满摄像头挖孔区。
  - 迷你播放条拖动边界按横屏安全区动态计算。

- **排布入口（谁分派两套 UI）**：`lib/src/responsive/landscape.dart`
  - `LandscapeGate`：`ref.watch(isLandscapeProvider)` 决定渲染 `portrait` 还是 `landscape` 子树。
  - `useLandscape(WidgetRef ref)`：局部 `if (ls)` 判断的便捷读法。

## 各页面横屏适配点（改一块就动这里）

| 页面 / 文件 | 竖屏 | 横屏（独立一套 UI） | 备注 |
| --- | --- | --- | --- |
| 设置 `settings_page.dart` | 分类列表 → 点入详情页 | **master-detail**：左侧分类导航，右侧对应详情内嵌，不跳页 | 页顶 `LandscapeGate(portrait:..., landscape:...)` |
| 我的 `mine_page.dart` | 完整版默认布局 | **精简个人中心**：账号区 + 数据统计 + 快捷卡片 **1×4 平铺**（参考桌面版首页）；顶部继承壳层全局顶栏；「账号设置」快捷卡内嵌打开账号页不开二级路由 | 音乐库入口在横屏由壳层侧栏接管，本页不再占用 |
| 播放·高级版 `player_page.dart` | 默认封面页 | 封面 + 歌词 + 控制条独立横向布局 | `LandscapeGate` 内 `_buildLandscapeAdvancedBody` |
| 播放·传统版 `player_page.dart` | 封面/歌词上下翻页 | **左封面｜右歌词并排** + 进度条 + 三区控制行 | `LandscapeGate` 内 `_buildTraditionalLandscape` |
| 首页 `home_page.dart` | 封面轮播 + 发现 + 听过最多 | **独立横屏 UI**：去掉封面卡片、直接以「发现」起步；顶部继承壳层全局顶栏（搜索 + 扫码 + 皮肤 + 设置）；「弦予音乐」标题移入左侧侧栏 | `build` 顶部 `useLandscape(ref)` 分流 `_buildPortrait` / `_buildLandscape`；顶栏由 `landscape_top_bar.dart` 全局提供 |

## 新增页面要接横屏？三步

1. 在页面顶层 build 返回 `LandscapeGate(portrait: _buildPortrait(context), landscape: _buildLandscape(context))`。
2. 把竖屏现有布局整体搬进 `_buildPortrait`，不动它。
3. 单独写 `_buildLandscape`（独立一套布局），只此一处动横屏。
   局部判断用 `useLandscape(ref)`，不要自己量屏幕。

然后在此 README 的「各页面横屏适配点」表里加一行。

## 约定 / 注意

- 所有弹窗（中心 / 选择 / 底部）使用独立路由淡进淡出，**不经切换动画开关**，与横屏无关。
- 横屏沉浸式铺摄像头由壳层统一处理；迷你条避让仍用原始 padding，各页面不要重复处理挖孔。
- 不要为取横屏态而 `import 'shell.dart'`（那是观察点）；应 `import '../responsive/landscape.dart'`（排布入口）。