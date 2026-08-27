package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 识曲样式（独立组件入口，launcher 组件列表单独可选）。
 *
 * 固定横条布局：左封面 + 右列（歌名/当前歌词 + 右上角听歌识曲按钮、
 * 上一首/播放/下一首、进度时间行）。右上识曲钮经深链
 * xianyu://open?target=recognize 拉起 App 识曲页；其余按钮与主组件共用
 * 广播控制链路（WidgetShared.handleAction）。
 */
class RecognizeWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        // 封面顶满容器上下：按各组件实际高度渲染方形位图（圆角对齐容器），逐 id 构建。
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                id,
                WidgetShared.buildRecognizeViews(
                    context, s, WidgetShared.widgetSizeDp(appWidgetManager, id)))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        // 固定布局不随尺寸切换，但封面需按新尺寸重渲染顶满容器。
        appWidgetManager.updateAppWidget(
            appWidgetId,
            WidgetShared.buildRecognizeViews(
                context,
                WidgetShared.stateJson(context) ?: JSONObject(),
                WidgetShared.sizeFromOptions(newOptions)))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}