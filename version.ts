/**
 * 应用版本号 —— 移动端唯一版本号源头（参考桌面端）。
 *
 * 修改版本号时只需修改此处的 APP_VERSION，
 * 然后运行 `dart run tool/sync_version.dart` 即可自动同步到：
 *   - pubspec.yaml（version 字段，保留 +build）
 *   - lib/src/auth/account_api.dart（appVersion 常量）
 *
 * 前端代码需读取版本号时，统一由同步脚本写入生成，不要直接改 account_api.dart 的 appVersion。
 */
export const APP_VERSION = '1.0.0-beta7';