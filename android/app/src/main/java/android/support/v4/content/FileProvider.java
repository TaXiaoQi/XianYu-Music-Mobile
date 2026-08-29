package android.support.v4.content;

/**
 * QQ OpenSDK 3.5.19 lite jar 运行时仍硬编码调用
 * android.support.v4.content.FileProvider.getUriForFile(Context, String, File)
 * （经 javap 反汇编确认，这是 SDK 唯一运行时用到的 support API，其余均为
 * 仅 Fragment 登录重载使用的 android.support.v4.app.Fragment）。
 *
 * 工程为纯 AndroidX，运行时不存在 support 库（Flutter 只注入 Fragment 编译
 * stub），直接调用会抛 NoClassDefFoundError 导致分享崩溃。此存根类继承
 * androidx.core.content.FileProvider，静态方法随父类解析，SDK 调用即落到
 * androidx 实现，行为与官方 jetifier 改写等价。
 */
public class FileProvider extends androidx.core.content.FileProvider {
}
