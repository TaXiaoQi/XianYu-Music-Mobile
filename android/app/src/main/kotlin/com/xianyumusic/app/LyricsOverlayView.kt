package com.xianyumusic.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin

/** 悬浮歌词单字数据（毫秒）。 */
data class LyricWordData(
    val text: String,
    val startMs: Long,
    val endMs: Long,
)

/** 悬浮歌词单行数据（毫秒）。 */
data class LyricLineData(
    val startMs: Long,
    val endMs: Long,
    val text: String,
    val translation: String?,
    val romaji: String?,
    val words: List<LyricWordData>,
    val secondary: List<String>,
)

/**
 * 透明悬浮歌词视图（移植自 RawS-Music DesktopLyricView）：
 * 卡拉OK逐字填充 + 逐字浮动动画 + 翻译/罗马音/背景歌词副行。
 * 播放进度由锚点 + elapsedRealtime 外推，保证 60fps 平滑。
 */
class LyricsOverlayView(context: Context) : View(context) {
    var touchHandler: ((View, MotionEvent) -> Boolean)? = null

    private var lines: List<LyricLineData> = emptyList()
    private var anchorPositionMs = 0L
    private var anchorRealtimeMs = SystemClock.elapsedRealtime()
    private var playing = false

    private var textColor = Color.WHITE
    private var opacity = 1f
    private var fontScale = 1f
    private var secondaryScale = 0.88f
    private var showTranslation = true
    private var showRomanization = false
    private var showBackground = true

    private val basePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = Paint.Align.LEFT
        setShadowLayer(5f, 0f, 1f, Color.argb(190, 0, 0, 0))
    }
    private val highlightPaint = Paint(basePaint)
    private val secondaryPaint = Paint(basePaint).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
    }

    // 跑马灯状态池：槽 0=主歌词，1..n=副行；文本超宽时循环滚动替代省略号。
    private val marqueeStates = Array(8) { MarqueeState() }

    init {
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun setLyrics(data: List<LyricLineData>) {
        lines = data
        invalidate()
    }

    fun setPlayback(positionMs: Long, isPlaying: Boolean) {
        anchorPositionMs = positionMs
        anchorRealtimeMs = SystemClock.elapsedRealtime()
        playing = isPlaying
        invalidate()
    }

    fun applyPreferences(
        color: Int,
        alpha: Float,
        scale: Float,
        secondaryScale: Float,
        showTranslation: Boolean,
        showRomanization: Boolean,
        showBackground: Boolean,
    ) {
        textColor = color
        opacity = alpha
        fontScale = scale
        this.secondaryScale = secondaryScale
        this.showTranslation = showTranslation
        this.showRomanization = showRomanization
        this.showBackground = showBackground
        invalidate()
    }

    /** 应用自定义歌词字体（空路径回退默认粗体），移植自 RawS resolveLyricTypeface。 */
    fun applyFont(path: String) {
        val typeface = if (path.isBlank() || !File(path).isFile) {
            Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        } else {
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    Typeface.Builder(File(path)).build()
                } else {
                    @Suppress("DEPRECATION")
                    Typeface.createFromFile(path)
                }
            }.getOrElse { Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }
        }
        basePaint.typeface = typeface
        highlightPaint.typeface = typeface
        secondaryPaint.typeface = typeface
        invalidate()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean =
        touchHandler?.invoke(this, event) ?: true

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val position = currentPosition()
        val line = findCurrentLine(position)
        if (line == null) {
            drawCenteredLine(canvas, "等待播放…", height * 0.48f)
        } else {
            drawLyricLine(canvas, line, position)
        }
        if (playing) postInvalidateOnAnimation()
    }

    private fun drawLyricLine(canvas: Canvas, line: LyricLineData, positionMs: Long) {
        val mainSize = sp(25f) * fontScale
        val secondarySize = sp(15f) * secondaryScale
        val maxWidth = width - dp(20)
        val originalText = line.text.ifBlank { "\u266a" }

        val lines = mutableListOf<Pair<String, List<LyricWordData>>>()
        if (showBackground) {
            line.secondary.forEach { lines += it to emptyList() }
        }
        if (showRomanization && !line.romaji.isNullOrBlank()) {
            lines += line.romaji.orEmpty() to emptyList()
        }
        if (showTranslation && !line.translation.isNullOrBlank()) {
            lines += line.translation.orEmpty() to emptyList()
        }

        val lineHeight = mainSize * 1.12f
        val secondaryHeight = secondarySize * 1.2f
        val totalHeight = lineHeight + lines.size * secondaryHeight
        basePaint.textSize = mainSize
        highlightPaint.textSize = mainSize
        secondaryPaint.textSize = secondarySize
        var baseline = (height - totalHeight) / 2f - basePaint.fontMetrics.top

        basePaint.color = withAlpha(textColor, opacity * 0.38f)
        highlightPaint.color = withAlpha(textColor, opacity)
        // 超宽不省略，改走跑马灯；暂停时冻结滚动时间避免跳变。
        val now = if (playing) SystemClock.elapsedRealtime() else anchorRealtimeMs
        val x = marqueeX(originalText, basePaint, maxWidth, 0, "main", line.startMs, now)
        val textWidth = basePaint.measureText(originalText)
        canvas.drawText(originalText, x, baseline, basePaint)
        val progress = wordProgress(line.words, line, positionMs)
        val wordLift = activeWordLift(line.words, positionMs)
        canvas.save()
        canvas.clipRect(
            x,
            baseline + basePaint.fontMetrics.top,
            x + textWidth * progress,
            baseline + basePaint.fontMetrics.bottom,
        )
        canvas.drawText(originalText, x, baseline - wordLift, highlightPaint)
        canvas.restore()

        secondaryPaint.color = withAlpha(textColor, opacity * 0.72f)
        lines.forEachIndexed { index, (secondary, _) ->
            baseline += secondaryHeight
            val secondaryX = marqueeX(
                secondary, secondaryPaint, maxWidth, index + 1, "sec$index", line.startMs, now
            )
            canvas.drawText(secondary, secondaryX, baseline, secondaryPaint)
        }
    }

    private fun drawCenteredLine(canvas: Canvas, text: String, centerY: Float) {
        basePaint.textSize = sp(22f) * fontScale
        basePaint.color = withAlpha(textColor, opacity)
        val x = (width - basePaint.measureText(text)) / 2f
        canvas.drawText(
            text,
            x,
            centerY - (basePaint.fontMetrics.ascent + basePaint.fontMetrics.descent) / 2f,
            basePaint,
        )
    }

    /**
     * 超宽文本跑马灯横向坐标：放得下时居中；放不下时从左边距起，
     * 起点停留 → 匀速左移至尾部可见 → 终点停留 → 循环。
     */
    private fun marqueeX(
        text: String,
        paint: Paint,
        maxWidth: Int,
        slot: Int,
        keyPrefix: String,
        lineStartMs: Long,
        now: Long,
    ): Float {
        val textWidth = paint.measureText(text)
        val travel = textWidth - maxWidth
        if (travel <= 0f) return (width - textWidth) / 2f
        val state = marqueeStates[slot.coerceIn(0, marqueeStates.lastIndex)]
        val progress = state.progress(
            "$keyPrefix:$lineStartMs:$text",
            travel,
            now,
            dp(MARQUEE_SPEED_DP) / 1000f,
        )
        return dp(10) - travel * progress
    }

    private fun wordProgress(words: List<LyricWordData>, line: LyricLineData, positionMs: Long): Float {
        if (words.isEmpty()) {
            val end = if (line.endMs > line.startMs) line.endMs else line.startMs + 3_000L
            return ((positionMs - line.startMs).toFloat() / (end - line.startMs).coerceAtLeast(1L))
                .coerceIn(0f, 1f)
        }
        val totalChars = words.sumOf { it.text.length }.coerceAtLeast(1)
        var completed = 0f
        words.forEach { word ->
            val length = word.text.length.toFloat()
            completed += when {
                positionMs >= word.endMs -> length
                positionMs <= word.startMs -> 0f
                else -> length * (
                    (positionMs - word.startMs).toFloat() /
                        (word.endMs - word.startMs).coerceAtLeast(1L)
                    ).coerceIn(0f, 1f)
            }
        }
        return (completed / totalChars).coerceIn(0f, 1f)
    }

    private fun currentPosition(): Long {
        if (!playing) return anchorPositionMs
        return anchorPositionMs + (SystemClock.elapsedRealtime() - anchorRealtimeMs)
    }

    private fun activeWordLift(words: List<LyricWordData>, positionMs: Long): Float {
        val active = words.firstOrNull { positionMs in it.startMs until maxOf(it.endMs, it.startMs + 1L) }
            ?: return 0f
        val progress = (
            (positionMs - active.startMs).toFloat() /
                (active.endMs - active.startMs).coerceAtLeast(1L)
            ).coerceIn(0f, 1f)
        return dp(1) * sin(PI * progress).toFloat()
    }

    private fun findCurrentLine(positionMs: Long): LyricLineData? {
        if (lines.isEmpty()) return null
        var lo = 0
        var hi = lines.size - 1
        while (lo < hi) {
            val mid = (lo + hi + 1) shr 1
            if (lines[mid].startMs <= positionMs) lo = mid else hi = mid - 1
        }
        val line = lines[lo]
        if (line.endMs > 0 && positionMs >= line.endMs) {
            for (i in lo + 1 until lines.size) {
                val l = lines[i]
                if (l.startMs <= positionMs && (l.endMs <= 0 || positionMs < l.endMs)) return l
                if (l.startMs > positionMs) break
            }
            return null
        }
        return line
    }

    private fun withAlpha(color: Int, alpha: Float): Int = Color.argb(
        (255 * alpha.coerceIn(0f, 1f)).roundToInt(),
        Color.red(color),
        Color.green(color),
        Color.blue(color),
    )

    private fun sp(value: Float): Float = value * resources.displayMetrics.scaledDensity
    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
}

/** 跑马灯循环参数：起点/终点停留毫秒数与滚动速度（dp/s）。 */
private const val MARQUEE_HOLD_START_MS = 600f
private const val MARQUEE_HOLD_END_MS = 900f
private const val MARQUEE_SPEED_DP = 30

/** 单条超宽文本的跑马灯状态（换行/换词通过 key 重置计时，Long 取模避免 Float 精度损失）。 */
private class MarqueeState {
    var key: String? = null
    var startRealtime = 0L

    /** 返回 0..1 的滚动进度：起点停留 → 匀速滚动 → 终点停留 → 循环。 */
    fun progress(key: String, travel: Float, now: Long, speedPxPerMs: Float): Float {
        if (key != this.key) {
            this.key = key
            startRealtime = now
        }
        if (travel <= 0f) return 0f
        val scrollMs = (travel / speedPxPerMs).toLong().coerceAtLeast(1L)
        val cycleMs = scrollMs + MARQUEE_HOLD_START_MS.toLong() + MARQUEE_HOLD_END_MS.toLong()
        val t = ((now - startRealtime) % cycleMs).toFloat()
        return when {
            t < MARQUEE_HOLD_START_MS -> 0f
            t < MARQUEE_HOLD_START_MS + scrollMs -> (t - MARQUEE_HOLD_START_MS) / scrollMs
            else -> 1f
        }
    }
}
