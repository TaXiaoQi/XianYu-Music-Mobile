# 主题中心 · 移动端 57 槽落点清单

> 依据：《主题中心-移动端客户端对接说明（v2）》的 §2 schema 与 §3 槽位清单。
> 基线：`a968cfa`（master，2026-09-30）。
> 本文只做**落点定位与改造归类**，供估工用；不改变任何契约。

## 0. 总览

| 归类 | 数量 | 含义 |
|---|---|---|
| **A 直接替换** | 41 | 该处已是可替换 widget 位，塞图 / 叠色即可 |
| **B 需改共享结构** | 11 | 图标来自共享模型，或组件被多处复用，改它会波及别处 |
| **C 需新建渲染点** | 4 | 该位置目前没有图标 / 容器 / 装饰 |
| **D 未找到落点** | 1 | 代码里不存在对应处（见 §4.1） |

**前提**：全库没有任何 `themeIcon()` / `themeSurface()` / `slotId` 接线，**57 槽全部需要从零接线**，不存在"接上即生效"的部分。

---

## 1. 图标 30 槽

| 槽位 | 落点 | 类 | 备注 |
|---|---|---|---|
| entry.search | `lib/src/widgets/page_search_bar.dart:52` | A | 5 处独立 Icon：另 `floating_search_bar.dart:34/421`、`landscape_top_bar.dart:404`、`settings_page.dart:145` |
| entry.mic | `lib/src/widgets/page_search_bar.dart:77` | A | 3 处：另 `floating_search_bar.dart:62`、`landscape_top_bar.dart:327` |
| **nav.home** | `lib/src/navigation/routes.dart:623` | **B** | 共享模型 `BottomNavItem.icon: IconData`，被底栏 / 侧栏 / 横屏 rail 三处读 |
| **nav.settings** | `lib/src/navigation/routes.dart:624` | **B** | 同上 |
| player.prev | `lib/src/widgets/mini_player_bar.dart:489` | A | 3 处：竖屏条 + 横屏胶囊同 widget；另 `player_page.dart:4669/4875` |
| player.play | `lib/src/widgets/mini_player_bar.dart:495` | A | 同上 3 处 |
| player.next | `lib/src/widgets/mini_player_bar.dart:502` | A | 同上 3 处 |
| **landscape.logo** | `lib/src/navigation/shell.dart:1515` | **C** | 横屏侧栏品牌当前是 `Text.rich` 纯文字，无图标位 |
| landscape.wallpaper | `lib/src/widgets/landscape_top_bar.dart:194` | A | 2 处；`SkinIcon` 为 CustomPaint 自绘 |
| landscape.settings | `lib/src/widgets/landscape_top_bar.dart:161` | A | 2 处 |
| entry.wallpaper | `lib/src/navigation/shell.dart:1074` | A | 2 处；`SkinIcon` 自绘 |
| mine.settings | `lib/src/navigation/shell.dart:1081` | A | 2 处 |
| entry.import | `lib/pages/mine/mine_page.dart:680` | A | "导入"胶囊 |
| mine.stat_listen | `lib/pages/home/discover_section.dart:64` | A | StatsSummaryCard |
| mine.stat_today | `lib/pages/home/discover_section.dart:73` | A | 同上 |
| mine.stat_count | `lib/pages/home/discover_section.dart:82` | A | 同上 |
| mine.grid_favorite | `lib/pages/mine/mine_page.dart:520` | A | 2 处：另 `:185`（横屏） |
| mine.grid_recent | `lib/pages/mine/mine_page.dart:526` | A | 2 处：另 `:186` |
| mine.grid_local | `lib/pages/mine/mine_page.dart:532` | A | 2 处：另 `:187` |
| mine.grid_download | `lib/pages/mine/mine_page.dart:540` | A | 2 处：另 `:189` |
| recognize.mic | `lib/pages/recognize/recognize_page.dart:570` | A | 76×76 圆钮主按钮 |
| player.queue | `lib/pages/player/player_page.dart:4702` | A | 2 处：另 `:4998`（横屏） |
| player.mode | `lib/pages/player/player_page.dart:4662` | A | 2 处；`_PlayModeIcon` 自绘 |
| **player.speed** | — | **D** | 播放页无倍速图标，详见 §4.1 |
| player.comment | `lib/pages/player/player_page.dart:1873` | A | 2 处：另 `:3583` |
| action.favorite | `lib/pages/player/player_page.dart:3546` | A | 3 处：另 `:4853`、`:1761` |
| action.download | `lib/pages/player/player_page.dart:3571` | A | 3 处：另 `:4830`、`:2136` |
| action.share | `lib/pages/player/player_page.dart:3559` | A | 2 处：另 `:1573`（横竖共用 `_buildTopBar`） |
| action.more | `lib/pages/player/player_page.dart:1919` | A | 封面动作行；`_TitleRow` 本身无 more |
| lib.drag | `lib/src/widgets/drag_handle.dart:100` | A | 共享 `DragHandle`，本地 / 收藏 / 最近三页复用 |

**B 类技术要点**：`BottomNavItem.icon` 现为 `IconData`（`lib/src/navigation/routes.dart:617`），渲染点 `shell.dart:2175`（底栏）、`shell.dart:2687`（侧栏）、`shell.dart:1629`（横屏 rail）。支持网络图需 widen 该字段（如"URL 优先、回落 IconData"）。

---

## 2. 组件色块 25 槽

| 槽位 | 落点 | 类 | 备注 |
|---|---|---|---|
| nav.bar | `lib/src/navigation/shell.dart:1180 / :1420 / :1386` | A | 3 条渲染路径（停靠 / 毛玻璃悬浮 / 液态） |
| mini.bar | `lib/src/widgets/mini_player_bar.dart:645` | A | 竖屏底条与横屏胶囊同 widget |
| search.box | `lib/src/widgets/glass_settings.dart:130` | A | ×5 共用 `searchBoxFill` |
| home.stat | `lib/src/widgets/cover_carousel.dart:195` | A | 硬编码渐变 `0xFF1E2638→surfaceContainerHigh` |
| **home.song** | `lib/pages/home/home_page.dart:221` | A | ⚠️ 与 `ls-home.most` 同 widget，见 §5 |
| mine.user | `lib/pages/mine/mine_page.dart:417` | A | |
| **mine.stats** | `lib/pages/home/discover_section.dart:356` | **B** | `_CardContainer` 被统计卡 / 每日推荐卡 / 榜单卡共用 |
| mine.grid | `lib/pages/mine/mine_page.dart:549` | A | |
| mine.sheet | `lib/pages/mine/mine_page.dart:643` | A | `_ReorderCard` 多列表复用 |
| recognize.hint | `lib/pages/recognize/recognize_page.dart:633` | A | |
| recognize.btn | `lib/pages/recognize/recognize_page.dart:559` | A | 硬编码红 + 状态色 |
| search.panel | `lib/pages/search/search_page.dart:1044` | A | `_IdleCard` |
| **search.item** | `lib/pages/search/search_page.dart:1125` | **C** | `_HotTile` 无底色容器，需新建 |
| sr.chips | `lib/pages/search/search_page.dart:810` | A/B | 浮动态玻璃填充；停靠态嵌入 `GlassTopBar` |
| **sr.pill** | `lib/src/widgets/floating_search_bar.dart:245` | **B** | 单槽应用到所有来源；`FloatingSourcePill` 亦被 `top_lists_page.dart:204` 复用 |
| **sr.item** | `lib/src/widgets/song_list_view.dart:38` | **B** | ⚠️ 与 `ls-lib.row` 同 widget，见 §5 |
| **settings.topbar** | `lib/src/widgets/glass_appbar.dart:83` | **B** | `GlassTopBar` 被首页 / 我的 / 搜索 / 识曲 / 设置多页复用 |
| **settings.group** | `lib/pages/settings/settings_page.dart:710` | **B** | `_CardGroup` 横屏左栏亦复用 |
| **ls-home.daily** | `lib/pages/home/discover_section.dart:169` | **B** | `_DailyCard` 横竖屏共用 |
| **ls-home.most** | `lib/pages/home/home_page.dart:221` | A | ⚠️ 与 `home.song` 同 widget，见 §5 |
| **ls-lib.row** | `lib/src/widgets/song_list_view.dart:38` | **B** | ⚠️ 与 `sr.item` 同 widget；本地 / 收藏 / 最近三页共用 |
| ls-sheets.card | `lib/pages/playlist/playlists_page.dart:278` | A | `appCardFill` |
| **ls-settings.nav** | `lib/pages/settings/settings_page.dart:283` | **C** | 左栏 `Material(color: transparent)`，无底色容器 |
| **ls-settings.detail** | `lib/pages/settings/account_settings_page.dart:652` | **B** | `_GlassCard` / `settings_category_page.dart:3116` |
| ls-mine.count | `lib/pages/mine/mine_page.dart:145` | A | `_StatsRow` |

✅ **已确认**：播放页（竖屏 / 横屏）**无任何色块落点**，与对接文档 §3.3 的约定一致。

---

## 3. 贴纸 2 槽

| 槽位 | 落点 | 类 | 备注 |
|---|---|---|---|
| **recognize.deco** | `lib/pages/recognize/recognize_page.dart:420`（外层 Stack） | **C** | 页面底部当前为空（无装饰图、无占位）；需新增 `Positioned(bottom:0)` 并自行约束宽高比 |
| **ls-sidebar.bottom** | `lib/src/navigation/shell.dart:1509`（`_LandscapeRail` Column 末尾） | **B** | 侧栏为**全局共享**（所有横屏页）；需兼顾 `collapsed` 窄栏态与 SafeArea |

---

## 4. 对接文档与实现不符的 4 处

### 4.1 `player.speed` —— 无落点（D）

全库"倍速"仅存在于 `lib/pages/effects/effects_page.dart`（滑杆，无图标）与 `lib/src/home/home_providers.dart`。播放页无倍速图标。

对接文档标注该槽"生效页 = 播放页" → **要么改指向音效页，要么取消该槽**。建议与编辑器侧确认。

### 4.2 `quickEntryShape` —— 声称"既有设置项写回"，实际不存在

全库搜 `quickEntryShape` / `entryShape` / `squircle` 零命中。我的页快捷宫格当前无形状设置项 → **存储 + 设置 UI + 渲染均需新建**，不是"写回"。

### 4.3 `landscape.logo` —— 无图标位

横屏侧栏品牌为 `Text.rich('弦予' + '音乐')`（`lib/src/navigation/shell.dart:1515`），非图标 → 需新增渲染点或替换该文字。

### 4.4 `recognize.deco` —— 无装饰位

识曲页外层 Stack 仅有"列表 Padding + 顶部玻璃栏 Positioned"，底部完全为空，且 `assets/` 下只有 `icon/`、`shaders/`，无贴纸素材 → 需新增。

---

## 5. 共享 widget 承载多个槽位（对接文档未提）

对接文档 §4.2 写"一槽多落点按槽位 id 查一次即可"，但下面这些是**一个 widget 承载两个不同槽位**，按槽位分别叠色会互相覆盖：

| 共享 widget | 承载的槽位 | 位置 |
|---|---|---|
| `_MostPlayedRow` | `home.song`（竖屏首页）+ `ls-home.most`（横屏发现） | `lib/pages/home/home_page.dart:208`（竖 / 横屏渲染同在此文件，`:85` / `:110`） |
| `CoverRow` | `sr.item`（搜索结果）+ `ls-lib.row`（横屏音乐库三页） | `lib/src/widgets/song_list_view.dart:38` |
| `_CardContainer` | `mine.stats` + 每日推荐卡 + 榜单卡 | `lib/pages/home/discover_section.dart:356` |

→ **接线时必须把槽位 id 从调用处传入这些共享 widget**，否则两槽互相覆盖。

---

## 6. 「导入 + 应用」链路的复用结论（不涉及渲染）

| 需要的能力 | 结论 |
|---|---|
| 写回强调色 / 深浅模式 | ✅ 直接复用 `setAccentColor` / `setThemeMode`（`lib/src/core/settings.dart:1143-1144`）；`lib/app.dart:268` 直接 watch → **立即生效，无需重启** |
| 选 `.json` 文件 | ✅ 有先例 `_importBackup`（`lib/pages/settings/settings_category_page.dart:3944`，file_picker） |
| `wallpaperRef:{id}` 应用壁纸 | ⚠️ **需新建**：壁纸中心是"下载到本地文件再应用"（`lib/pages/wallpaper/wallpaper_center_page.dart:477` → `setCustomBackground`），**无"按 id 取壁纸"的现成入口** |
| 主题包本地存储 | ⚠️ 无通用封装；建议并入 `AppSettings`（增 `themePacks` / `activeThemeId`），复用其 prefs 写入（`lib/src/core/settings.dart:983`） |
| 既有"整包主题"机制 | ❌ 不存在（`皮肤` 按钮只是跳转 `/wallpaper`）→ 全新，不会重复造轮子 |
| 四 Tab 主题中心页 | ❌ **阻塞**：依赖《主题中心-客户端对接文档.md》的服务端接口（签名通道、`list_themes` / `my_themes` / `upload_theme`、审核流程），该文档未提供 |

---

## 7. 建议的落地切分（按风险递增）

1. **阶段 1 · 导入 + 应用**（不碰渲染架构）：模型层解析 v2 JSON、存储层并入 `AppSettings`、应用时调既有 setter。可独立验收。
2. **阶段 2 · 色块 25 槽**：先接 3 个公共块（`nav.bar` / `mini.bar` / `search.box`）见效最快；再做 A 类其余、C 类两处新建容器；B 类 8 处需在共享 widget 上加槽位参数（见 §5）。
3. **阶段 3 · 图标 30 槽 + 贴纸 2 槽**：26 个 A 类逐个替换；`nav.home` / `nav.settings` 需先 widen `BottomNavItem.icon`；`landscape.logo`、`recognize.deco` 需新建渲染点；`player.speed` 待文档澄清。

**横屏风险集中在**：`landscape.logo`、`ls-settings.nav`（均 C 类新建）+ `ls-sidebar.bottom`（改全局共享侧栏）。
