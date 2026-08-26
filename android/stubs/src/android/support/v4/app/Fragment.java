package android.support.v4.app;

/**
 * 编译期桩类：tencent_kit 6.2.0 捆绑的 open_sdk_3.5.17.3_lite.jar 的
 * Tencent.login(Fragment, ...) 方法签名引用了已从 AndroidX 工程移除的
 * android.support.v4.app.Fragment，javac 解析签名时需要该类存在。
 * 应用实际只调用 login(Activity, ...) 重载，运行时不会用到本桩类。
 */
public class Fragment {
    public Fragment() {}
}
