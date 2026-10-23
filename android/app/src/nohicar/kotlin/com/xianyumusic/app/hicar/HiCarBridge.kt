package com.xianyumusic.app.hicar

import android.app.Activity

/**
 * HiCar 桥接 · 空实现（AAR 缺省 sourceSet）。
 *
 * 构建期条件切换：app/libs/huawei-hicar-sdk.aar 存在时，Gradle 把本目录
 * 替换为 src/hicar/kotlin（真实现），MainActivity 的调用点代码不变。
 * 两份文件的类名/方法签名必须保持一致。
 */
object HiCarBridge {
    fun init(activity: Activity) {}
}
