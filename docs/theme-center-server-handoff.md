# 主题中心 · 服务端交接（`我的下载` 已定：服务端不做）

> 来源：客户端（`Xianyu-Music-Mobile`）主题中心页开发过程中的实际依赖。
> 所有关于服务端的描述均从当前服务端代码读出（`XianYu-Music-Server`），非猜测；已定的结论与仍未定的部分分别标明。
>
> **结论速览：服务端本项无待做。** `我的下载` 走客户端本地记录（见第三节）。
> 服务端本轮仅修了本地调试桩的形状（见第六节），不涉及生产接口。

## 一、背景

客户端主题中心已做成四 Tab：**本地 / 广场 / 我的上传 / 我的下载**。

- **本地**：读客户端已导入的主题，不涉及服务端
- **广场**：已接 `list_themes`
- **我的上传**：已接 `my_themes`
- **我的下载**：**服务端无对应 action，且已定不由服务端提供** —— 详见第三节

## 二、现状（服务端已有）

分发入口：`server/src/handlers/mod.rs` 第 103-106 行，`/api/` 单入口按 `action` 名分发：

| action | 实现 | 客户端用途 |
|---|---|---|
| `list_themes` | `handlers/theme.rs` | 广场 |
| `my_themes` | `handlers/theme.rs` | 我的上传 |
| `upload_theme` | `handlers/theme.rs` | 上传 |

行为细节（读代码所得）：

- `list_themes`：入参 `platform`；SQL 只取 `status = 'normal'`，按 `sort_order DESC, id DESC`
- `my_themes`：入参 `ciyuanxi_id` + `platform`；**弦予号为空直接返回 400**；SQL 取 `uploaded_by = ?`，**不按 `status` 过滤**（故含待审）
- 两者都返回 `ctx.ok("ok", list)`，`list` 是**数组**
- 条目字段由 `row_to_theme` 组装（见下）

## 三、`我的下载`：已定（路线 2 · 客户端本地记录）

**决定：走路线 2 —— 服务端不为「我的下载」新增任何东西。** 客户端自己维护已下载列表。

服务端确认无下载记录（`themes` 表无下载字段、无下载 action），就此保持不动：
**服务端不提供 `my_downloads`，也不需要 `download_theme` 写入动作。**

选这条的依据是客户端侧已有一份权威数据 —— `themeLibraryProvider`
（`lib/src/theme/theme_store.dart`）：它以 SharedPreferences 持久化已导入的
`ThemePackage` 列表，正是"本地"Tab 的数据源，导入入口是 `importJson()`。
**"用户下载过哪些主题"在客户端本地本来就存着**，再在服务端存一份等于双数据源，
还要额外定义"取消下载/删除本地主题时如何删记录"，否则列表残留。

代价（已知并接受）：**不跨设备同步** —— 换设备或重装后该列表为空。

> 若日后改为要跨端一致，再回到路线 1。届时建议形态（**当前不要实现**）：
> action 名 `my_downloads`，入参 `ciyuanxi_id` + `platform`（空号返 400），
> 返回 `ctx.ok("ok", <数组>)` 且元素复用 `row_to_theme`；另需写入动作
> `download_theme`（入参 `theme_id` + `ciyuanxi_id`）。

## 四、客户端对接约定（请服务端保持一致，否则客户端会报错）

1. **数组必须放在 `data` 里，不要包成 Map。**
   客户端对返回数组的 action 走 `AuthNotifier.requestActionList`；而 `requestAction` 会把 `data` 强转成 `Map`，数组走它会**运行时抛类型错**。（这个坑客户端已实际踩过一次，见 `account_api.dart` 的 `listThemes` / `myThemes` 注释。）
2. **成功码是 `code == 200`。**
3. **字段名用 camelCase**，且与 `row_to_theme` 现有字段保持一致：
   `id` / `name` / `description` / `platform` / `theme` / `previewUrl` / `thumbnailUrl` / `uploaderId` / `uploaderNickname` / `status` / `reviewedAt` / `reviewedBy` / `createdAt`
4. **`theme` 字段就是 v2 主题包 payload**，客户端会直接 `jsonEncode` 后交给已有的导入器——请勿改变其结构。

## 五、客户端侧现状（供服务端判断影响面）

- 网络层已就绪：`lib/src/auth/account_api.dart` 的 `listThemes()` / `myThemes()`
- 模型层：`lib/src/theme/remote_theme.dart`（`RemoteTheme`）
- 数据层：`lib/src/theme/remote_theme_store.dart`（`themeSquareProvider` / `myThemesProvider`）
- 页面：`lib/pages/theme/theme_center_page.dart`（"我的下载" Tab 目前是**占位提示**）
- 上述客户端改动**尚未提交**（截至本文档撰写时）

## 六、验收建议

因为定了路线 2（服务端不参与），原"服务端对接口"类的验收项已不适用。改为：

**客户端侧"我的下载"上线前请确认：**

- 列表直接取自 `themeLibraryProvider`，与"本地"Tab 同源、往返一致
- 刚导入（下载）的主题立即可见，删除本地主题后同步消失 —— 不存在"记录说下载过、本地却没有"的残留
- 未登录 / 无任何下载时应显示**空列表**，而不是错误提示

**服务端侧本轮已做的改动（与本交接单相关，供知悉）：**

- `server/src/debug.rs` 中 `list_wallpapers` / `my_wallpapers` / `list_themes` /
  `my_themes` 四个本地调试桩，原先返回 `{total, list}` **Map**，与真实接口的
  **数组**形状不符，违反上面第四节第 1 条 —— 已改为数组并对齐字段名。
  另将 `list_themes` 桩的 `theme` 由 `null` 补成可导入的 v2 mobile 包
  （客户端 `RemoteTheme.fromJson` 在 `theme` 非对象时会整条跳过，
  仅改数组形状而 `theme` 仍为 `null` 的话，列表依旧为空）。
  已用 `LOCAL_DEBUG_NO_DB` 模式实测四个 action 均返回数组。
  **仅影响本地调试模式**，生产与部署包 `local_debug_no_db` 均为 `false`。
