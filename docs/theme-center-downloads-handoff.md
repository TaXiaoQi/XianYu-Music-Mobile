# 主题中心 · 「我的下载」客户端实现交接

> 承接 [`theme-center-server-handoff.md`](theme-center-server-handoff.md) 的**第三节结论**。
>
> ## ⚠️ 最终决定（写就后变更，以此为准）
>
> 产品最终选择**删除「我的下载」Tab**：既不走客户端本地记录，也不需要服务端提供
> `my_downloads` / `download_theme`。依据就是本文第 1 节 —— 主题层没有来源信息，
> 「下载」与「导入」在数据上不可区分，做出来只会是「本地」的重复页。
>
> **因此第 2 ~ 5 节中"如何在客户端实现我的下载"的路径指引已作废**（原文按「路线 2
> 客户端本地记录」撰写）。第 1 节的问题分析、第 6 节 i18n 缺口、第 7 节的代码修复
> 建议仍然有效。
>
> 客户端侧对应改动已提交：`e8f4612`（删除该 Tab，四 Tab 改三 Tab）。
>
> 服务端至今无需任何改动（原第三节的 `my_downloads` / `download_theme` 均不实施）。
>
> 基线：`3a4c564`（master，2026-09-30）。所有代码引用均从该基线读出，非猜测。

## 0. 一句话结论

「我的下载」不能直接等于「本地」——两者若要分得开，**必须新增"主题来源"记录**，
而当前主题层**完全没有来源信息**。这是本项工作的核心，其余都是外围。

---

## 1. 核心问题：本地库不记录来源

现状（读代码所得）：

- `ThemePackage`（`lib/src/theme/theme_package.dart`）的字段只有
  `id / name / author / preview / accentColor / themeMode / wallpaperId /
  quickEntryShape / icons / stickers / surfaces / raw` —— **没有"从哪来"**。
- `ThemeLibraryState`（`lib/src/theme/theme_store.dart:9-12`）只有
  `packages` + `activeId`，同样不含来源。
- 持久化只有两个键（`theme_store.dart:42-43`）：
  `xianyu_theme_packs_v1`（包 JSON 字符串列表）、`xianyu_active_theme_id_v1`。

因此「本地」Tab（`theme_center_page.dart:123-133`，渲染 `library.packages`）
与「我的下载」若都取 `library.packages`，**两个 Tab 内容完全一样**，"下载"这个
概念在数据上不存在。

### 1.1 而且"下载"与"导入"在数据上无法区分

- 从**广场**获取主题走 `_applyRemote`（`theme_center_page.dart:212-226`）：
  `importJson(jsonEncode(theme.payload))` → `activate`。
- 从**文件**导入走 `_import`（`theme_center_page.dart:29-67`）：同样是
  `importJson(content)`。

两条路进的是**同一个方法、同一个持久化键**，事后无法分辨某条包是"下载来的"
还是"文件导入的"。

### 1.2 附带事实：本地包 id 是内容哈希，不是服务端主题 id

`ThemePackage.id` 由 `FNV-1a(name|author|preview|version)` 派生
（`theme_package.dart:164-173`），与 `themes.id`（服务端自增主键）**毫无关系**，
且 `importJson` 存在同 id 覆盖去重（`theme_store.dart:61-70`）。

含义有两点，实现时必须考虑：

- 无法用本地 `pkg.id` 反查服务端主题，也拿不到 `uploaderId` / `status` 等字段
  ——服务端那些字段在导入时就被丢弃了（`raw` 只存了 payload）。
- **同一个主题"先下载、后文件导入"（或反之）会合并成一条**，来源标记会变得暧昧
  （见 §4.1）。

---

## 2. 两条互斥路线（先选一条，再动手）

| | 做法 | 结果 |
|---|---|---|
| **A 加来源记录**（推荐） | 记录哪些包是"从广场下载"的，「我的下载」= 本地库的**子集** | 四个 Tab 语义成立，与已有决策一致 |
| **B 不加来源** | 「我的下载」直接复用 `library.packages` | 与「本地」Tab **完全重复**；此时正确做法是从 TabBar **删掉该 Tab**（4 → 3），而不是实现一个重复页 |

**推荐 A。** 因为「我的下载」这个 Tab 的存在本身就隐含"与本地不同"的产品意图；
若产品其实认为「本地」已覆盖，那就是 B，应删 Tab 而非做重复页。
**这一条建议先与产品确认**，否则可能白做。

---

## 3. 若选 A：建议实现路径

思路：**不改 `ThemePackage`、不改包 JSON 格式**，只额外记一份 id 集合，
完全对齐现有 `activeId` 的写法（`theme_store.dart:42-55`）。

### 3.1 数据层（`lib/src/theme/theme_store.dart`）

1. 新增持久化键，命名对齐现有风格：
   ```dart
   static const _downloadedKey = 'xianyu_downloaded_theme_ids_v1';
   ```
2. `ThemeLibraryState` 增加一个字段（保持 `const` 构造与默认值）：
   ```dart
   final Set<String> downloadedIds;   // 默认 const <String>{}
   ```
3. `_init()`（`theme_store.dart:45-57`）从 prefs 载入该列表，并按
   **`activeId` 的同款做法做净化**——只保留仍存在于 `packages` 里的 id
   （参考 `theme_store.dart:55` 对 `saved` 的处理），避免删包后残留。
4. `importJson` 增加可选参数，**默认值保证现有调用方零改动**：
   ```dart
   Future<ThemePackage?> importJson(String text, {bool fromSquare = false})
   ```
   为 `true` 时把 `pkg.id` 记入 `downloadedIds`。
   > 注意 `_persist()` 的时机：新标记也要一并落盘，别只更新内存。
5. `remove(id)`（`theme_store.dart:72-78`）**必须同时**从 `downloadedIds` 剔除，
   否则删掉包后 id 残留（下次同 id 再导入会"诈尸"成已下载）。

### 3.2 接线上传来源（`lib/pages/theme/theme_center_page.dart`）

- `_applyRemote`（`:212-226`）是**唯一**的"从广场下载"入口，改这里：
  `importJson(jsonEncode(theme.payload), fromSquare: true)`。
- `_import`（`:29-67`）**不要**传该参数（文件导入不算下载）。

### 3.3 页面层（`lib/pages/theme/theme_center_page.dart`）

- 把「本地」Tab 内联的 `ListView`（`:123-133`）**抽成一个复用方法**，例如
  `Widget _libraryList(ColorScheme scheme, List<ThemePackage> pkgs)`，
  由「本地」传 `library.packages`、「我的下载」传筛选后的子集。
  这样两 Tab 的卡片样式、应用/取消应用/删除行为天然一致（复用 `_packageCard`
  `:246-312`），不会各写一套。
- 替换占位 `_downloadsHint(scheme)`（调用点 `:136`，定义 `:176-182`）。
- 空态文案必须改掉现在的"依赖服务端接口，待接入后开放"（`:181`）——
  该说法在路线 2 下不再成立。建议改为空列表提示 + 指向「广场」的引导。
- 顺手修一处**过期注释**：类文档注释 `:18` 仍写着
  "广场 / 我的上传 / 我的下载依赖服务端接口，待接入后补"——
  前两者早已接好，此注释已失真。

### 3.4 列表要不要三态？

`_remoteList`（`:149-174`）的加载/失败/列表三态是给**远程**数据用的。
本地库是同步的（`ref.watch(themeLibraryProvider)` 直接拿值），
「我的下载」**不需要** `AsyncValue` 那套，用普通 `ListView` + 空态即可。

---

## 4. 需要拍板的产品细节

### 4.1 同 id 去重时，"已下载"标记怎么办

因 §1.2 的合并行为，会出现：

- 先下载 X、后文件导入同一个 X → `importJson` 合并为一条且 `fromSquare: false`
- 先文件导入 X、后从广场下载 X → 合并为一条且被标记

**建议**：标记**只增不减**（一旦下载过就算下载过，后续文件导入不抹除），
理由是与"用户确实下载过它"的直觉一致，且实现最简。若要更精细，就得把
来源从"包的属性"改成"导入事件"的记录，成本明显上升——**不建议**为这个边角做。

### 4.2 "下载"是否要与"应用"分离

现在点广场条目是**一步到位**：`_applyRemote` = 导入 **+** `activate`（`:222`）。
即"下载即应用"。于是「我的下载」里出现的，实际上都是**已被应用过至少一次**的主题。

若产品期望"只下载、不应用"（例如列表项加个下载按钮、点进详情再应用），
那是**新的交互设计**，不是本次补 Tab 的范围。可用的现成挂点是
`RemoteThemeTile.trailing`（`remote_theme_tile.dart:17,22`，目前全库无人使用）。
**建议本次不做**，先按"下载即应用"上线，除非产品明确要求分离。

### 4.3 与服务端字段的取舍

因 §1.2，「我的下载」列表**拿不到** `uploaderNickname` / `status` / 缩略图 URL
等服务端字段（导入时已丢）。所以该 Tab 应复用**本地卡片** `_packageCard`
（显示 name / author / 槽位摘要 / 本地预览图），而**不是** `RemoteThemeTile`
（后者依赖 `RemoteTheme`，那些字段此时并不存在）。
这也是 §3.3 建议复用 `_packageCard` 的原因之一。

---

## 5. 国际化（容易漏）

`tr()` 的取值逻辑（`lib/src/i18n/i18n.dart:33-48`）：

- `zhCn`：原样返回
- `zhTw`：`twDict[source] ??` 自动简转繁 → **不登记也能用**
- `en`：`enDict[source] ?? source` → **不登记就显示中文**

所以新增的中文串**必须登记到 `lib/src/i18n/en_dict_manual.dart`**，
格式为 `'中文': 'English',`（见该文件开头示例）。

另外发现一处**既有缺口**：主题中心这一整页的串在英文/繁中词典里**基本都不存在**
（`en_dict_manual.dart` 里只有 3 条含"主题"的词条，且都不是本页文案），
即当前英文模式下整个主题中心页显示中文。例如：

- `主题中心` / `我的上传` / `我的下载` / `暂无主题`
- `还没有导入主题包` / `该页依赖服务端接口，待接入后开放`

修不修由你定；但**本次新增的串必须登记**，否则是在缺口上再加缺口。

---

## 6. 测试

现成范本：[`test/theme_package_import_test.dart`](../test/theme_package_import_test.dart)
（`ProviderContainer` + `SharedPreferences.setMockInitialValues`，`group`
分「解析」「Notifier」「渲染入口」等）。建议在同文件或新文件补：

- 导入时 `fromSquare: false` **不**产生下载标记；`true` 则产生
- `remove(id)` 后该 id 从下载集合消失
- **重启后**（新建 `ProviderContainer`）下载标记从 prefs 恢复
  （参考现有"重启后从 prefs 恢复导入列表与激活状态"用例，`:190-205`）
- prefs 里的下载 id 指向已不存在的包时被净化掉
  （参考 `:221-232` 对 `activeId` 的同类用例）
- 删除后再以同 id 导入：不应被误判为"已下载"

---

## 7. 验收清单

- [ ] 「本地」列出**全部**已导入包；「我的下载」只列**从广场下载过**的子集
- [ ] 广场点一条 → 出现在「我的下载」，且「本地」也有
- [ ] 文件导入一条 → 出现在「本地」，**不**出现在「我的下载」
- [ ] 删除某条 → 两个 Tab 同步消失（本地库同源，不会一处留一处不留）
- [ ] 下载集合随 prefs 跨重启保持
- [ ] 无下载记录时显示**空态**（不是错误、也不是空白页）
- [ ] 占位文案"依赖服务端接口"已移除；`:18` 过期注释已修
- [ ] 新增中文串已在 `en_dict_manual.dart` 登记
- [ ] `flutter test` 通过（含上述新增用例）

---

## 8. 明确不做

- 服务端任何改动（`my_downloads` / `download_theme` / 建表）——按路线 2 已定不做
- 「只下载不应用」的交互分离（见 §4.2，除非产品另有要求）
- 为同 id 去重做"导入事件级"的来源追踪（见 §4.1，成本不划算）
- 跨设备同步下载记录（路线 2 已明确接受的代价）