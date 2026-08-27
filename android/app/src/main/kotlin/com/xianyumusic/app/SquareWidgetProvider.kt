package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 方形 2×2 样式（独立组件入口，launcher 组件列表单独可选）。
 *
 * 固定方形布局：上部大封面 + 下部歌名 + 右侧小播放键。
 * 控制链路与主组件共用（WidgetShared）。
 */
class SquareWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        // 封面按各组件实际尺寸渲染（圆角绝对 24dp 对齐容器），逐 id 构建。
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                id,
                WidgetShared.buildViews(
                    context, s, WidgetShared.MODE_2X2, SquareWidgetProvider::class.java, 4000,
                    WidgetShared.widgetSizeDp(appWidgetManager, id)))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        // 固定样式不随尺寸切换，但封面需按新尺寸重渲染对齐容器圆角。
        appWidgetManager.updateAppWidget(
            appWidgetId,
            WidgetShared.buildViews(
                context,
                WidgetShared.stateJson(context) ?: JSONObject(),
                WidgetShared.MODE_2X2,
                SquareWidgetProvider::class.java,
                4000,
                WidgetShared.sizeFromOptions(newOptions)))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}