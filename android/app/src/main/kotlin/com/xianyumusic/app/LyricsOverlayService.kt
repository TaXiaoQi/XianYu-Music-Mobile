package com.xianyumusic.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 悬浮歌词窗服务（移植自 RawS-Music DesktopLyricService）。
 *
 * 数据全部由 Flutter 侧驱动（歌词/播放进度/设置经 MethodChannel 推送），
 * 本服务只负责渲染与交互：卡拉OK逐字填充、拖拽移动、双击/长按唤出控制条、
 * 锁定（通知解锁）、颜色/字号循环。控制动作经事件通道回调 Flutter 执行播放。
 */
class LyricsOverlayService : Service() {
    private lateinit var windowManager: WindowManager
    private lateinit var notificationManager: NotificationManager
    private var rootView: LinearLayout? = null
    private var lyricView: LyricsOverlayView? = null
    private var controlsView: LinearLayout? = null
    private var playPauseButton: ImageButton? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var eventsChannel: MethodChannel? = null

    // 由 Flutter 推送的运行时数据（内存态，持久化在 Flutter 侧）。
    private var lyricsJson = ""
    private var positionMs = 0L
    private var playing = false
    private var textColor = Color.WHITE
    private var opacity = 1f
    private var fontScale = 1f
    private var secondaryScale = 0.88f
    private var showTranslation = true
    private var showRomanization = false
    private var showBackground = true
    private var hideWhenPaused = false
    private var hideInLandscape = false
    private var widthPercent = 92
    private var useLyricFont = false
    private var lyricFontPath = ""
    private var locked = false
    private var xPos = 0
    private var yPos = 96

    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var movedDuringTouch = false
    private var longPressTriggered = false
    private var lastTapTimeMs = 0L

    private val hideControlsRunnable = Runnable { hideControls() }
    private val longPressRunnable = Runnable {
        longPressTriggered = true
        showControlsWithAnimation()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        FlutterMessengerHolder.messenger?.let {
            eventsChannel = MethodChannel(it, EVENTS_CHANNEL)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> disableAndStop()
            ACTION_UNLOCK -> {
                locked = false
                applySettings(revealControls = true)
                // 通知解锁需同步回 Flutter 持久化锁定状态。
                emitEvent("onUnlock")
            }
            else -> showOverlayIfAllowed()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        updateVisibility()
        updateWindowLayout()
    }

    override fun onDestroy() {
        instance = null
        rootView?.removeCallbacks(hideControlsRunnable)
        rootView?.let { runCatching { windowManager.removeView(it) } }
        rootView = null
        lyricView = null
        controlsView = null
        playPauseButton = null
        layoutParams = null
        notificationManager.cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    // ---- 数据入口（由 MainActivity 的 MethodChannel 转发） ----

    fun setLyrics(json: String) {
        lyricsJson = json
        lyricView?.setLyrics(parseLyrics(json))
    }

    fun setPlayback(posMs: Long, isPlaying: Boolean) {
        positionMs = posMs
        playing = isPlaying
        lyricView?.setPlayback(posMs, isPlaying)
        playPauseButton?.setImageResource(if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play)
        updateVisibility(isPlaying)
    }

    fun setSettings(json: String) {
        parseSettings(json)
        applySettings(revealControls = false)
    }

    fun setLocked(lock: Boolean) {
        locked = lock
        applySettings(revealControls = false)
    }

    fun resetPosition() {
        xPos = 0
        yPos = 96
        layoutParams?.let { params ->
            params.x = 0
            params.y = 96
            rootView?.let { runCatching { windowManager.updateViewLayout(it, params) } }
        }
    }

    // ---- 生命周期 ----

    private fun showOverlayIfAllowed() {
        if (!canDrawOverlay()) {
            stopSelf()
            return
        }
        if (rootView == null) addOverlay()
        applySettings(revealControls = false)
        lyricView?.setLyrics(parseLyrics(lyricsJson))
        lyricView?.setPlayback(positionMs, playing)
    }

    private fun addOverlay() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        val lyric = LyricsOverlayView(this).apply {
            touchHandler = ::onDrag
        }
        val controls = createControls()
        root.addView(
            lyric,
            LinearLayout.LayoutParams(overlayWidth(), overlayHeight())
        )
        root.addView(
            controls,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(44)
            ).apply { gravity = Gravity.CENTER_HORIZONTAL }
        )

        val baseFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            if (locked) baseFlags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else baseFlags,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = xPos
            y = yPos
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        rootView = root
        lyricView = lyric
        controlsView = controls
        layoutParams = params
        controls.visibility = View.GONE
        windowManager.addView(root, params)
        clampToScreen(root, params)
        windowManager.updateViewLayout(root, params)
    }

    private fun createControls(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(5), dp(4), dp(5), dp(4))
            background = GradientDrawable().apply {
                cornerRadius = dp(24).toFloat()
                setColor(Color.argb(176, 30, 30, 30))
            }
            addIconControl(R.drawable.ic_skip_previous, "上一首") {
                emitEvent("onPrevious")
            }
            playPauseButton = addIconControl(
                R.drawable.ic_play,
                "播放/暂停"
            ) {
                emitEvent("onTogglePlayback")
            }
            addIconControl(R.drawable.ic_skip_next, "下一首") {
                emitEvent("onNext")
            }
            addIconControl(
                R.drawable.ic_desktop_lyric_text_smaller,
                "缩小字号"
            ) { emitEvent("onFontSmaller") }
            addIconControl(
                R.drawable.ic_desktop_lyric_text_larger,
                "放大字号"
            ) { emitEvent("onFontLarger") }
            addIconControl(
                R.drawable.ic_palette,
                "切换颜色"
            ) { emitEvent("onColorCycle") }
            addTextControl("L", "锁定") { emitEvent("onLock") }
            addIconControl(R.drawable.ic_close, "关闭") { emitEvent("onClose") }
        }
    }

    private fun LinearLayout.addIconControl(
        icon: Int,
        description: String,
        action: () -> Unit
    ): ImageButton {
        val button = ImageButton(context).apply {
            setImageResource(icon)
            setColorFilter(Color.WHITE)
            contentDescription = description
            scaleType = ImageView.ScaleType.CENTER
            background = controlBackground()
            setPadding(dp(8), dp(8), dp(8), dp(8))
            setOnClickListener {
                action()
                scheduleControlsAutoHide()
            }
        }
        addView(button, controlLayoutParams())
        return button
    }

    private fun LinearLayout.addTextControl(label: String, description: String, action: () -> Unit) {
        addView(TextView(context).apply {
            text = label
            contentDescription = description
            gravity = Gravity.CENTER
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            background = controlBackground()
            setOnClickListener {
                action()
                scheduleControlsAutoHide()
            }
        }, controlLayoutParams())
    }

    private fun controlLayoutParams() = LinearLayout.LayoutParams(dp(34), dp(34)).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
    }

    private fun controlBackground() = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.argb(52, 255, 255, 255))
    }

    private fun emitEvent(method: String, args: Any? = null) {
        runCatching { eventsChannel?.invokeMethod(method, args) }
    }

    // ---- 设置 ----

    private fun parseSettings(json: String) {
        if (json.isBlank()) return
        runCatching {
            val o = JSONObject(json)
            textColor = o.optInt("textColor", Color.WHITE)
            opacity = (o.optInt("opacity", 100) / 100f).coerceIn(0f, 1f)
            fontScale = (o.optInt("fontScale", 100) / 100f).coerceIn(0.4f, 2.5f)
            secondaryScale = (o.optInt("secondaryScale", 88) / 100f).coerceIn(0.4f, 2.5f)
            showTranslation = o.optBoolean("showTranslation", true)
            showRomanization = o.optBoolean("showRomanization", false)
            showBackground = o.optBoolean("showBackground", true)
            hideWhenPaused = o.optBoolean("hideWhenPaused", false)
            hideInLandscape = o.optBoolean("hideInLandscape", false)
            widthPercent = o.optInt("widthPercent", 92).coerceIn(40, 100)
            useLyricFont = o.optBoolean("useLyricFont", false)
            lyricFontPath = o.optString("lyricFontPath", "")
            locked = o.optBoolean("locked", false)
            xPos = o.optInt("x", 0)
            yPos = o.optInt("y", 96)
        }
    }

    private fun applySettings(revealControls: Boolean) {
        if (!canDrawOverlay()) {
            stopSelf()
            return
        }
        if (rootView == null) addOverlay()
        lyricView?.applyPreferences(
            textColor,
            opacity,
            fontScale,
            secondaryScale,
            showTranslation,
            showRomanization,
            showBackground,
        )
        lyricView?.applyFont(
            if (useLyricFont) lyricFontPath else ""
        )
        lyricView?.setLyrics(parseLyrics(lyricsJson))
        lyricView?.setPlayback(positionMs, playing)
        updateWindowLayout()
        setLocked(locked, revealControls)
        updateVisibility()
    }

    private fun updateWindowLayout() {
        val root = rootView ?: return
        val params = layoutParams ?: return
        lyricView?.layoutParams = lyricView?.layoutParams?.apply {
            width = overlayWidth()
            height = overlayHeight()
        }
        params.x = xPos
        params.y = yPos
        clampToScreen(root, params)
        runCatching { windowManager.updateViewLayout(root, params) }
    }

    private fun updateVisibility(playingOverride: Boolean? = null) {
        val isPlaying = playingOverride ?: playing
        val hidden = (hideWhenPaused && !isPlaying) ||
            (
                hideInLandscape &&
                    resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
                )
        rootView?.visibility = if (hidden) View.GONE else View.VISIBLE
    }

    private fun setLocked(lock: Boolean, revealControls: Boolean = true) {
        val params = layoutParams ?: return
        params.flags = if (lock) {
            params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        } else {
            params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        }
        controlsView?.visibility =
            if (!lock && revealControls) View.VISIBLE else View.GONE
        rootView?.let { runCatching { windowManager.updateViewLayout(it, params) } }
        if (lock) postUnlockNotification() else notificationManager.cancel(NOTIFICATION_ID)
        if (!lock && revealControls) scheduleControlsAutoHide()
    }

    // ---- 拖拽 / 点按 ----

    private fun onDrag(view: View, event: MotionEvent): Boolean {
        if (locked) return false
        val params = layoutParams ?: return false
        val root = rootView ?: view
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.rawX
                downY = event.rawY
                startX = params.x
                startY = params.y
                movedDuringTouch = false
                longPressTriggered = false
                root.removeCallbacks(longPressRunnable)
                root.postDelayed(longPressRunnable, LONG_PRESS_TIMEOUT_MS)
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (abs(dx) > dp(4) || abs(dy) > dp(4)) {
                    movedDuringTouch = true
                    root.removeCallbacks(longPressRunnable)
                }
                params.x = startX + dx.roundToInt()
                params.y = startY + dy.roundToInt()
                clampToScreen(root, params)
                windowManager.updateViewLayout(root, params)
            }
            MotionEvent.ACTION_UP -> {
                root.removeCallbacks(longPressRunnable)
                if (!movedDuringTouch && !longPressTriggered) handleTap()
                xPos = params.x
                yPos = params.y
                emitEvent("onPositionChanged", mapOf("x" to xPos, "y" to yPos))
            }
            MotionEvent.ACTION_CANCEL -> root.removeCallbacks(longPressRunnable)
        }
        return true
    }

    private fun handleTap() {
        val now = SystemClock.uptimeMillis()
        if (now - lastTapTimeMs <= DOUBLE_TAP_TIMEOUT_MS) {
            showControlsWithAnimation()
            lastTapTimeMs = 0L
        } else {
            lastTapTimeMs = now
        }
    }

    private fun scheduleControlsAutoHide() {
        rootView?.removeCallbacks(hideControlsRunnable)
        rootView?.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_MS)
    }

    private fun showControlsWithAnimation() {
        if (locked) return
        controlsView?.apply {
            animate().cancel()
            visibility = View.VISIBLE
            alpha = 0f
            scaleX = CONTROL_HIDDEN_SCALE
            scaleY = CONTROL_HIDDEN_SCALE
            animate()
                .alpha(1f)
                .scaleX(1f)
                .scaleY(1f)
                .setDuration(CONTROL_ANIMATION_MS)
                .start()
        }
        scheduleControlsAutoHide()
    }

    private fun hideControls() {
        if (!locked) {
            controlsView?.apply {
                animate().cancel()
                animate()
                    .alpha(0f)
                    .scaleX(CONTROL_HIDDEN_SCALE)
                    .scaleY(CONTROL_HIDDEN_SCALE)
                    .setDuration(CONTROL_ANIMATION_MS)
                    .withEndAction {
                        visibility = View.GONE
                        alpha = 1f
                        scaleX = 1f
                        scaleY = 1f
                    }
                    .start()
            }
        }
    }

    private fun clampToScreen(view: View, params: WindowManager.LayoutParams) {
        val width = view.width.takeIf { it > 0 } ?: overlayWidth()
        val height = view.height.takeIf { it > 0 } ?: overlayHeight()
        val maxX = (resources.displayMetrics.widthPixels / 2 - width / 2).coerceAtLeast(0)
        val maxY = (resources.displayMetrics.heightPixels - height).coerceAtLeast(0)
        params.x = params.x.coerceIn(-maxX, maxX)
        params.y = params.y.coerceIn(-statusBarHeight(), maxY)
    }

    private fun overlayWidth(): Int {
        return (resources.displayMetrics.widthPixels * widthPercent / 100f)
            .roundToInt()
            .coerceIn(dp(180), resources.displayMetrics.widthPixels - dp(12))
    }

    private fun overlayHeight(): Int = dp(150)

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }

    // ---- 锁定通知 ----

    private fun postUnlockNotification() {
        ensureNotificationChannel()
        val unlockIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, LyricsOverlayService::class.java).setAction(ACTION_UNLOCK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        runCatching {
            notificationManager.notify(
                NOTIFICATION_ID,
                builder
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle("悬浮歌词已锁定")
                    .setContentText("点击解锁后可拖动位置")
                    .setContentIntent(unlockIntent)
                    .setOngoing(true)
                    .setShowWhen(false)
                    .build()
            )
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (notificationManager.getNotificationChannel(CHANNEL_ID) != null) return
        notificationManager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "悬浮歌词",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
        )
    }

    private fun disableAndStop() {
        rootView?.let { runCatching { windowManager.removeView(it) } }
        rootView = null
        lyricView = null
        controlsView = null
        playPauseButton = null
        layoutParams = null
        notificationManager.cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun canDrawOverlay(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    // ---- 歌词解析 ----

    private fun parseLyrics(json: String): List<LyricLineData> {
        if (json.isBlank()) return emptyList()
        return runCatching {
            val root = JSONObject(json)
            val arr = root.optJSONArray("lines") ?: return emptyList()
            val result = ArrayList<LyricLineData>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val words = ArrayList<LyricWordData>()
                val wordsArr = o.optJSONArray("words")
                if (wordsArr != null) {
                    for (j in 0 until wordsArr.length()) {
                        val w = wordsArr.optJSONObject(j) ?: continue
                        words.add(
                            LyricWordData(
                                text = w.optString("text", ""),
                                startMs = (w.optDouble("start", 0.0) * 1000).toLong(),
                                endMs = (w.optDouble("end", 0.0) * 1000).toLong(),
                            )
                        )
                    }
                }
                val secondary = ArrayList<String>()
                val secArr = o.optJSONArray("secondary")
                if (secArr != null) {
                    for (j in 0 until secArr.length()) {
                        secArr.optString(j).takeIf { it.isNotBlank() }?.let { secondary.add(it) }
                    }
                }
                result.add(
                    LyricLineData(
                        startMs = o.optLong("startMs", 0L),
                        endMs = o.optLong("endMs", 0L),
                        text = o.optString("text", ""),
                        translation = o.optString("translation", "").takeIf { it.isNotBlank() },
                        romaji = o.optString("romaji", "").takeIf { it.isNotBlank() },
                        words = words,
                        secondary = secondary,
                    )
                )
            }
            result
        }.getOrElse { emptyList() }
    }

    companion object {
        const val ACTION_ENABLE = "com.example.xianyu.action.ENABLE_FLOATING_LYRIC"
        const val ACTION_HIDE = "com.example.xianyu.action.HIDE_FLOATING_LYRIC"
        const val ACTION_UNLOCK = "com.example.xianyu.action.UNLOCK_FLOATING_LYRIC"
        const val CHANNEL = "xianyu/floating_lyrics"
        const val EVENTS_CHANNEL = "xianyu/floating_lyrics_events"

        private const val CHANNEL_ID = "xianyu_floating_lyric"
        private const val NOTIFICATION_ID = 0x52444C59
        private const val CONTROLS_AUTO_HIDE_MS = 4_000L
        private const val DOUBLE_TAP_TIMEOUT_MS = 360L
        private const val LONG_PRESS_TIMEOUT_MS = 460L
        private const val CONTROL_ANIMATION_MS = 220L
        private const val CONTROL_HIDDEN_SCALE = 0.8f

        @Volatile
        var instance: LyricsOverlayService? = null

        fun canDraw(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

        fun permissionIntent(context: Context): Intent =
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}")
            )

        fun show(context: Context) {
            runCatching {
                context.startService(Intent(context, LyricsOverlayService::class.java).setAction(ACTION_ENABLE))
            }
        }

        fun hide(context: Context) {
            runCatching {
                context.startService(Intent(context, LyricsOverlayService::class.java).setAction(ACTION_HIDE))
            }
        }
    }
}

/** 持有 Flutter 引擎 messenger，供服务创建事件通道回调 Flutter。 */
object FlutterMessengerHolder {
    @Volatile
    var messenger: BinaryMessenger? = null
}
