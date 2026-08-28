package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 方形（独立组件入口，launcher 组件列表单独可选）。
 *
 * 多档自适应：拖拽在 2×2 方形 / 4×2 横条 / 4×3 歌词卡之间切换
 * （档位判定见 WidgetShared.squareCellMode / buildEntry）。
 * 控制链路与主组件共用（WidgetShared.handleAction）。
 */
class SquareWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                id, WidgetShared.buildEntry(
                    context, s, id, SquareWidgetProvider::class.java,
                    4000, WidgetShared.MODE_2X2, false))
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
                SquareWidgetProvider::class.java,
                4000,
                WidgetShared.MODE_2X2,
                false))
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        for (id in appWidgetIds) WidgetShared.clearId(id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}