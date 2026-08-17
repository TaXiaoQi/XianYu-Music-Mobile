# 弦予音乐 · 移动主页设计稿

> 融合 **桌面版视觉风格** + **RawS 布局**，作为 Flutter 移动端主页重构的基线。
> 高保真预览见同目录 `mobile-home-mockup.html`。

## 一、设计目标

| 来源 | 取用部分 |
|------|---------|
| 桌面版（XianYu-Music-Desktop） | 网易云红 `#EC4141`、暗色 `#262626`、Inter 字体、毛玻璃材质、频谱/旋转/淡入动效、"播放中"红色徽章 |
| RawS（XY-Music-Mobile） | 主页自上而下编排：顶部栏 → 搜索 → 封面轮播 → 音乐库网格 → 听过最多 → 工具网格；液态玻璃浮动底栏；旋转封面+环形进度迷你播放器 |
| 弦予 Flutter 端 | 沿用 `go_router` + Riverpod 架构，把当前"音乐库即主页"升级为独立"主界面"首页 |

## 二、主页布局结构（自上而下）

```
┌───────────────────────────┐
│ 1 顶部栏（48dp）            │  ☰ 弦予音乐  ◐背景切换 ⚙设置
│ 2 毛玻璃搜索栏（44dp）       │  胶囊形，点击进全局搜索
│ 3 封面轮播 ★焦点（~312dp）   │  当前播放队列封面横滑 + 歌曲信息遮罩 + 红色"播放中"徽章
│ 4 「音乐库」标题 + 全部 ›     │
│ 5 音乐库网格 2×3            │  歌曲/文件夹/专辑/歌手/歌单/最近添加
│ 6 「听过最多」标题            │
│ 7 听过最多列表（3~10 行）     │  毛玻璃行卡 + 播放次数 + 红色播放钮
│ 8 迷你播放器（浮动，58dp）    │  旋转封面 + 环形进度 + 信息 + 播放/下一首，上拖展开全屏
│ 9 液态玻璃底栏（60dp，浮动）  │  主界面·音乐库·音效·搜索·设置（5 Tab 可自定义）
└───────────────────────────┘
```

## 三、视觉规范

### 配色

| 用途 | 色值 |
|------|------|
| 主题色 Primary | `#EC4141`（网易云红） |
| 主题色悬停 | `#b92f2f` |
| 暗色背景 | `#262626`（非纯黑，Win11 风格） |
| 次级背景 | `#1f1f1f` / `#2c2c2c` / `#333333` |
| 毛玻璃底 | `rgba(38,38,38,0.55)` ~ `rgba(48,48,48,0.72)` |
| 边框 | `rgba(255,255,255,0.08)` |
| 正文 | `#f2f2f4` |
| 次要文字 | `rgba(242,242,244,0.62)` / `0.40` |

### 字体与字号

- 全局：`Inter, ui-sans-serif, system-ui, "PingFang SC", "Microsoft YaHei"`
- 区块标题：21px / 700
- 封面歌曲名：22px / 700
- 卡片标题：15px / 600
- 正文：14~15px
- 副文字/标签：11~12px

### 圆角

| 元素 | 圆角 |
|------|------|
| 卡片/网格方块 | 13px |
| 轮播容器/大封面 | 24px |
| 迷你播放器/底栏 | 999px（胶囊） |
| 搜索栏 | 999px |
| 图标块 | 10px |

### 毛玻璃

- `backdrop-filter: blur(18~22px) saturate(140~150%)`
- 应用到：搜索栏、封面歌曲信息遮罩、网格行卡、迷你播放器、底栏
- 无窗口材质时由 CSS backdrop-blur 兜底

### 阴影

- 卡片/浮层：`0 8px 30px rgba(0,0,0,0.45)`
- 轮播红光：`0 14px 40px rgba(236,65,65,0.18)`
- 底栏/迷你播放器：`0 8px 26px rgba(0,0,0,0.4)`

## 四、交互与动效

| 元素 | 动效 |
|------|------|
| 封面轮播 | 横滑 `cubic-bezier(.22,1,.36,1)` 0.5s，4s 自动轮播，悬停暂停 |
| "播放中"徽章 | 三根频谱条 `scaleY` 1s 循环（0/0.2/0.4s 延迟） |
| 迷你封面 | `rotate(360deg)` 8s 线性，暂停时 `animation-play-state: paused` |
| 网格卡片 | hover `translateY(-2px)` + 红色边框 |
| 底栏切换 | 选中态红色文字 + 底部红点，0.18s 过渡 |
| 播放/按钮 | `active: scale(.9)` |
| 页面进场 | `opacity + translateY(8px)` 0.3s（对齐桌面版 page-fade） |

## 五、与当前实现的差异与迁移路径

当前 Flutter 端（`library_page.dart`）以"音乐库"为主页，无独立首页、无封面图、无在线发现流。迁移步骤：

1. **新增主界面页** `lib/pages/home/home_page.dart`，作为 `/` 路由，承载上述布局；`/library` 降为底栏二级页。
2. **底栏扩为 5 Tab**：主界面 / 音乐库 / 音效 / 搜索 / 设置。修改 `routes.dart` 的 `bottomNavItems` 与 `shell.dart`。
3. **封面轮播组件** `lib/src/widgets/cover_carousel.dart`：从 `playerProvider` 队列取封面，WebDAV/本地缓存加载图片，复用桌面版红色徽章 + 频谱动效。
4. **音乐库网格** `lib/src/widgets/library_grid.dart`：6 入口，渐变图标块（Material `Container` + `LinearGradient`）。
5. **听过最多** 复用 `libraryProvider` + 播放次数排序（需服务端 `listen_stats` 或本地播放记录）。
6. **迷你播放器** 重构 `mini_player_bar.dart`：旋转封面 + 环形进度（`CustomPainter`）+ 上拖展开（`DraggableScrollableSheet` 或 `PageView`）。
7. **液态玻璃底栏**：`BackdropFilter` 包裹 `NavigationBar`，选中态取 `colorScheme.primary`。
8. **主题** 默认强调色由 `#E0245E` 改为 `#EC4141`，暗色背景固定 `#262626`。

## 六、关键文件参考

| 桌面版参考 | 作用 |
|-----------|------|
| `XianYu-Music-Desktop/src/components/layout/PlayerFooter.vue` | 底栏播放控制 + 跑马灯 |
| `XianYu-Music-Desktop/src/components/song-list/SongTable.vue` | 频谱条 + 红色徽章 |
| `XianYu-Music-Desktop/src/components/layout/GlobalBackground.vue` | 流光背景 |
| `XianYu-Music-Desktop/src/style.css` | 主题色 / 字体 / 暗色变量 |

| RawS 参考 | 作用 |
|----------|------|
| `XY-Music-Mobile/core/ui/.../scene/pages/HomePage.kt` | 主页布局骨架 |
| `XY-Music-Mobile/.../widget/bottombar/LiquidBottomTabs.kt` | 液态玻璃底栏 |
| `XY-Music-Mobile/.../widget/MiniPlayerView.kt` | 旋转封面+环形进度迷你播放器 |

| 弦予 Flutter 待改 | 作用 |
|-------------------|------|
| `lib/src/navigation/routes.dart` | 路由 + 底栏 Tab 定义 |
| `lib/src/navigation/shell.dart` | AppShell + NavigationBar |
| `lib/pages/library/library_page.dart` | 当前"主页"，将降为二级 |
| `lib/src/widgets/mini_player_bar.dart` | 待重构为旋转封面版 |
| `lib/src/core/settings.dart` | 主题强调色默认值 |

## 七、备注

- 封面图当前为 CSS 渐变占位；正式实现时接入 WebDAV/本地缓存的真实封面。
- 暗色模式为默认；亮色模式按桌面版 `#fafafa/#ffffff` 反相，毛玻璃透明度相应调低。
- 性能模式（RawS 已有）：低端机可降级为纯色半透明背景，去掉 backdrop-filter 以省电。
