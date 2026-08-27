package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 方形（独立组件入口，launcher 组件列表单独可选）。
 *
 * 多档自适应：随桌面上拖拽尺寸在 2×2 方形 / 4×2 横条 / 3×4 歌词卡 三档间切换
 * （档位由 WidgetShared.squareCellMode 按网格尺寸判定，onAppWidgetOptionsChanged
 * 落盘到 layout_<id>，onUpdate/refresh 按已存档档位构建）。
 */
class SquareWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, WidgetShared.buildSquareViews(context, s, id))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        // 按新尺寸判定档位并落盘，后续刷新按该档位构建。
        val mode = WidgetShared.squareCellMode(newOptions)
        context.getSharedPreferences(WidgetShared.SP_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(WidgetShared.LAYOUT_PREFIX + appWidgetId, mode)
            .apply()
        appWidgetManager.updateAppWidget(
            appWidgetId,
            WidgetShared.buildSquareViews(
                context, WidgetShared.stateJson(context) ?: JSONObject(), appWidgetId))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}