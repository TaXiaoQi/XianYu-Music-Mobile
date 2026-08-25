package com.example.xianyu_music_mobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
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
        val clippedText = ellipsize(originalText, basePaint, maxWidth)
        val x = (width - basePaint.measureText(clippedText)) / 2f
        canvas.drawText(clippedText, x, baseline, basePaint)
        val progress = wordProgress(line.words, line, positionMs)
        val wordLift = activeWordLift(line.words, positionMs)
        val textWidth = basePaint.measureText(clippedText)
        canvas.save()
        canvas.clipRect(
            x,
            baseline + basePaint.fontMetrics.top,
            x + textWidth * progress,
            baseline + basePaint.fontMetrics.bottom,
        )
        canvas.drawText(clippedText, x, baseline - wordLift, highlightPaint)
        canvas.restore()

        secondaryPaint.color = withAlpha(textColor, opacity * 0.72f)
        lines.forEach { (secondary, _) ->
            baseline += secondaryHeight
            val display = ellipsize(secondary, secondaryPaint, maxWidth)
            val secondaryX = (width - secondaryPaint.measureText(display)) / 2f
            canvas.drawText(display, secondaryX, baseline, secondaryPaint)
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

    private fun ellipsize(text: String, paint: Paint, maxWidth: Int): String {
        if (paint.measureText(text) <= maxWidth) return text
        val ellipsis = "\u2026"
        var end = text.length
        while (end > 0 && paint.measureText(text.substring(0, end) + ellipsis) > maxWidth) end--
        return text.substring(0, end) + ellipsis
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
