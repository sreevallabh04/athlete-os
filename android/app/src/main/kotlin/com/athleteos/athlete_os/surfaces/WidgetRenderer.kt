package com.athleteos.athlete_os.surfaces

import android.content.Context
import android.view.View
import android.widget.RemoteViews
import com.athleteos.athlete_os.R
import java.text.NumberFormat
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Builds the widget's RemoteViews. Honesty rules (same as the Dart
 * snapshot builder): a value is shown only when it was logged/synced today;
 * otherwise "—" next to the target. A snapshot from another day is never
 * shown as today's.
 */
object WidgetRenderer {
    private const val DASH = "—"

    class Model(val data: WidgetData?, val now: ZonedDateTime, val pendingWaterMl: Int) {
        /** The snapshot when it belongs to today, else null. */
        fun today(): WidgetData? = data?.takeIf { it.date == now.toLocalDate().toString() }
    }

    private data class Ids(val cell: Int, val value: Int, val target: Int, val bar: Int, val gold: Int)

    private val STEPS = Ids(R.id.surf_cell_steps, R.id.surf_val_steps, R.id.surf_tgt_steps, R.id.surf_bar_steps, R.id.surf_barg_steps)
    private val PROTEIN = Ids(R.id.surf_cell_protein, R.id.surf_val_protein, R.id.surf_tgt_protein, R.id.surf_bar_protein, R.id.surf_barg_protein)
    private val KCAL = Ids(R.id.surf_cell_kcal, R.id.surf_val_kcal, R.id.surf_tgt_kcal, R.id.surf_bar_kcal, R.id.surf_barg_kcal)
    private val WATER = Ids(R.id.surf_cell_water, R.id.surf_val_water, R.id.surf_tgt_water, R.id.surf_bar_water, R.id.surf_barg_water)

    private const val COLOR_TEXT = 0xFFF4F1EC.toInt()
    private const val COLOR_MUTED = 0xFFA8A299.toInt()
    private const val COLOR_GOLD = 0xFFF2B544.toInt()

    fun build(ctx: Context, model: Model, wide: Boolean): RemoteViews {
        val layout = if (wide) R.layout.surf_widget_wide else R.layout.surf_widget_compact
        val v = RemoteViews(ctx.packageName, layout)
        val today = model.today()

        // Targets come from the profile; they are shown even for a stale day.
        val d = model.data
        val water = today?.water ?: WidgetMetric(null, d?.water?.target)
        val waterValue = when {
            model.pendingWaterMl > 0 -> (water.value ?: 0.0) + model.pendingWaterMl
            else -> water.value
        }

        metric(v, STEPS, today?.steps?.value, d?.steps?.target, ::fmtCount, ::fmtStepsTarget)
        metric(v, PROTEIN, today?.protein?.value, d?.protein?.target, ::fmtInt) { "/${fmtInt(it)} g" }
        metric(v, KCAL, today?.calories?.value, d?.calories?.target, ::fmtCount) { "/${fmtCount(it)}" }
        metric(v, WATER, waterValue, water.target, ::fmtLitres) { "/${fmtLitres(it)} L" }

        v.setTextViewText(R.id.surf_updated, updatedLabel(d, model.now))

        if (wide) {
            header(v, today)
            next(v, model, today)
        }

        // Tap targets: each section opens its screen; the button logs water.
        v.setOnClickPendingIntent(R.id.surf_root, SurfaceActions.openLink(ctx, "today", 7310))
        v.setOnClickPendingIntent(R.id.surf_header, SurfaceActions.openLink(ctx, "today", 7310))
        v.setOnClickPendingIntent(STEPS.cell, SurfaceActions.openLink(ctx, "steps", 7311))
        v.setOnClickPendingIntent(PROTEIN.cell, SurfaceActions.openLink(ctx, "nutrition", 7312))
        v.setOnClickPendingIntent(KCAL.cell, SurfaceActions.openLink(ctx, "nutrition", 7312))
        v.setOnClickPendingIntent(WATER.cell, SurfaceActions.openLink(ctx, "hydration", 7313))
        if (wide) {
            v.setOnClickPendingIntent(R.id.surf_session, SurfaceActions.openLink(ctx, "session", 7314))
            v.setOnClickPendingIntent(R.id.surf_next, SurfaceActions.openLink(ctx, "routine", 7315))
        }
        v.setOnClickPendingIntent(R.id.surf_water_btn, SurfaceActions.logWaterBroadcast(ctx, "widget", 7320))
        return v
    }

    private fun metric(
        v: RemoteViews,
        ids: Ids,
        value: Double?,
        target: Double?,
        fmtValue: (Double) -> String,
        fmtTarget: (Double) -> String,
    ) {
        val reached = value != null && target != null && value >= target
        v.setTextViewText(ids.value, if (value == null) DASH else fmtValue(value))
        v.setTextColor(ids.value, if (value == null) COLOR_MUTED else if (reached) COLOR_GOLD else COLOR_TEXT)
        v.setTextViewText(ids.target, if (target == null) "" else fmtTarget(target))
        val progress = if (value == null || target == null || target <= 0) 0 else
            ((value / target).coerceIn(0.0, 1.0) * 1000).roundToInt()
        v.setProgressBar(ids.bar, 1000, progress, false)
        v.setViewVisibility(ids.bar, if (reached) View.GONE else View.VISIBLE)
        v.setViewVisibility(ids.gold, if (reached) View.VISIBLE else View.GONE)
    }

    private fun header(v: RemoteViews, today: WidgetData?) {
        val title = today?.sessionTitle
        when {
            title == null -> {
                v.setTextViewText(R.id.surf_session, "TODAY")
                v.setTextColor(R.id.surf_session, COLOR_MUTED)
            }
            today?.sessionDone == true -> {
                v.setTextViewText(R.id.surf_session, "✓ $title")
                v.setTextColor(R.id.surf_session, COLOR_GOLD)
            }
            else -> {
                v.setTextViewText(R.id.surf_session, title)
                v.setTextColor(R.id.surf_session, COLOR_TEXT)
            }
        }
    }

    private fun next(v: RemoteViews, model: Model, today: WidgetData?) {
        val minute = model.now.hour * 60 + model.now.minute
        val (label, time, title) = when {
            model.data == null -> Triple("SYNC", "", "Open Athlete OS once to connect")
            today == null -> Triple("SYNC", "", "Open Athlete OS to refresh today")
            today.routine.isEmpty() -> Triple("PLAN", "", "No routine yet · calibrate JARVIS")
            else -> {
                val n = today.nextBlock(minute + 1)
                if (n != null) Triple("NEXT", hhmm(n.start), n.title)
                else Triple("DONE", "", "Day complete")
            }
        }
        v.setTextViewText(R.id.surf_next_label, label)
        v.setTextViewText(R.id.surf_next_time, time)
        v.setViewVisibility(R.id.surf_next_time, if (time.isEmpty()) View.GONE else View.VISIBLE)
        v.setTextViewText(R.id.surf_next_title, title)
    }

    private fun updatedLabel(d: WidgetData?, now: ZonedDateTime): String {
        if (d == null || d.updatedAt <= 0) return DASH
        val at = Instant.ofEpochMilli(d.updatedAt).atZone(now.zone)
        val fmt = if (at.toLocalDate() == now.toLocalDate()) "HH:mm" else "d MMM"
        return at.format(DateTimeFormatter.ofPattern(fmt, Locale.getDefault()))
    }

    private fun hhmm(minutes: Int): String {
        val m = ((minutes % 1440) + 1440) % 1440
        return String.format(Locale.US, "%02d:%02d", m / 60, m % 60)
    }

    private fun fmtCount(x: Double): String {
        val n = x.roundToInt()
        if (n >= 100_000) return "${n / 1000}k"
        return NumberFormat.getIntegerInstance(Locale.getDefault()).format(n)
    }

    private fun fmtInt(x: Double): String = x.roundToInt().toString()

    private fun fmtStepsTarget(x: Double): String {
        val n = x.roundToInt()
        return if (n >= 1000 && n % 1000 == 0) "/${n / 1000}k"
        else if (n >= 1000) "/" + String.format(Locale.US, "%.1fk", n / 1000.0)
        else "/$n"
    }

    /** Millilitres → litres with up to 2 decimals ("1.25", "1.5", "2"). */
    private fun fmtLitres(ml: Double): String {
        val l = (ml / 10).roundToInt() / 100.0
        return if (l == l.toLong().toDouble()) l.toLong().toString()
        else String.format(Locale.US, "%.2f", l).trimEnd('0').trimEnd('.')
    }
}
