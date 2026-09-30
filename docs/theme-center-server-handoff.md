# 主题中心 · 服务端待做事项（客户端交接）

> 来源：客户端（`Xianyu-Music-Mobile`）主题中心页开发过程中的实际依赖。
> 所有关于服务端的描述均从当前服务端代码读出（`XianYu-Music-Server`），非猜测；未定的部分已明确标为**待定**。

## 一、背景

客户端主题中心已做成四 Tab：**本地 / 广场 / 我的上传 / 我的下载**。

- **本地**：读客户端已导入的主题，不涉及服务端
- **广场**：已接 `list_themes`
- **我的上传**：已接 `my_themes`
- **我的下载**：**服务端没有对应 action，尚未接** —— 就是本文档要交接的事

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

## 三、需要服务端做的：`我的下载`

### 待定（需服务端/产品先明确语义）

客户端目前**只能**假设"我的下载 = 该用户下载过的主题"，但服务端**当前没有任何下载记录**：

- 没有记录下载行为的表/字段
- 没有触发记录的 action（如"记录一次下载"）

所以有两条路，**请先选一条**：

1. **服务端记录**（客户端当前按此推进）：新增下载记录（表 + 写入动作），再提供查询 action
2. **客户端本地记录**：服务端不动，客户端自己存已下载列表 —— 若选这条，请明确告知，客户端会改实现

### 若选路线 1：建议接口形态

为降低双方成本，建议**对齐现有 `my_themes` 的形态**：

- action 名：建议 `my_downloads`（与 `my_themes` 对称；名称可商量）
- 入参：`ciyuanxi_id` + `platform`（与 `my_themes` 一致）；弦予号为空同样返回 400
- 返回：与 `list_themes` / `my_themes` 一致 —— `ctx.ok("ok", <数组>)`，数组元素用**同一个 `row_to_theme`** 组装

另外需要一个**写入动作**（例如 `download_theme`），入参含 `theme_id` + `ciyuanxi_id`，供客户端在用户下载时调用。

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

服务端补完后，客户端"我的下载"上线前请一并确认：

- 无下载记录时返回**空数组**（而不是错误）
- 弦予号为空时返回 **400**（与 `my_themes` 行为一致）
- `data` 是**数组**（不是 `{list: [...]}` 这类包裹）
