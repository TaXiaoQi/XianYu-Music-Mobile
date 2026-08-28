package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 识曲（独立组件入口，launcher 组件列表单独可选）。
 *
 * 多档自适应：拖拽在 2×2 方形 / 4×2 横条 / 4×3 歌词卡之间切换；
 * 4×2 横条档位显示右上角听歌识曲按钮，经深链
 * xianyu://open?target=recognize 拉起 App 识曲页，其余入口不显示该按钮。
 * 其余按钮与主组件共用广播控制链路（WidgetShared.handleAction）。
 */
class RecognizeWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                id, WidgetShared.buildEntry(
                    context, s, id, RecognizeWidgetProvider::class.java,
                    2000, WidgetShared.MODE_4X2, true))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        val mode = WidgetShared.squareCellMode(newOptions)
        context.getSharedPreferences(WidgetShared.SP_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(WidgetShared.LAYOUT_PREFIX + appWidgetId, mode)
            .apply()
        appWidgetManager.updateAppWidget(
            appWidgetId,
            WidgetShared.buildEntry(
                context,
                WidgetShared.stateJson(context) ?: JSONObject(),
                appWidgetId,
                RecognizeWidgetProvider::class.java,
                2000,
                WidgetShared.MODE_4X2,
                true))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}