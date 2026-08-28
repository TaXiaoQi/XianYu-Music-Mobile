package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 歌词卡（独立组件入口，launcher 组件列表单独可选）。
 *
 * 多档自适应：拖拽在 2×2 方形 / 4×2 横条 / 4×3 歌词卡之间切换；
 * 4×3 档位为五行歌词窗口（当前行固定居中加粗），并支持逐字播放高亮。
 * 控制链路与主组件共用（WidgetShared.handleAction）。
 */
class LyricWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                id, WidgetShared.buildEntry(
                    context, s, id, LyricWidgetProvider::class.java,
                    5000, WidgetShared.MODE_LYRIC, false))
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
                LyricWidgetProvider::class.java,
                5000,
                WidgetShared.MODE_LYRIC,
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