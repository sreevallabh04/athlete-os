package com.athleteos.athlete_os.surfaces

import android.app.AlarmManager
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * "JARVIS Today" home-screen widget.
 *
 * Rendering is fully native (RemoteViews) from the last snapshot Flutter
 * pushed into [SurfaceStore], so the widget stays correct — and keeps
 * picking the right "next" routine block — without starting the Flutter
 * engine. Updates happen when:
 *  * Flutter pushes a changed snapshot (≤ 1 per 15 s),
 *  * a water tap is queued (immediate),
 *  * the system's periodic update fires (`updatePeriodMillis`, 30 min),
 *  * a non-wakeup alarm reaches the next routine block / midnight.
 */
class JarvisTodayWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        render(context, manager, appWidgetIds)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, manager, intArrayOf(appWidgetId))
    }

    override fun onDisabled(context: Context) {
        // Last widget removed: stop the boundary alarm.
        try {
            context.getSystemService(AlarmManager::class.java)?.cancel(SurfaceActions.refreshBroadcast(context))
        } catch (_: Throwable) {
        }
    }

    companion object {
        /** Wide layout from this width (dp); below it the compact one. */
        private const val WIDE_MIN_DP = 250f

        fun ids(ctx: Context): IntArray {
            val mgr = AppWidgetManager.getInstance(ctx) ?: return IntArray(0)
            return mgr.getAppWidgetIds(ComponentName(ctx, JarvisTodayWidget::class.java))
        }

        /** Re-renders every placed widget from the stored snapshot. */
        fun updateAll(ctx: Context) {
            val app = ctx.applicationContext
            val mgr = AppWidgetManager.getInstance(app) ?: return
            val ids = ids(app)
            if (ids.isEmpty()) return
            render(app, mgr, ids)
        }

        private fun render(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
            if (ids.isEmpty()) return
            val now = ZonedDateTime.now()
            val data = try { SurfaceStore.snapshot(ctx) } catch (_: Throwable) { null }
            val dayStart = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val pending = try {
                SurfaceStore.pendingWaterMl(ctx, data?.updatedAt ?: 0L, dayStart)
            } catch (_: Throwable) {
                0
            }
            val model = WidgetRenderer.Model(data, now, pending)
            for (id in ids) {
                try {
                    val views = if (Build.VERSION.SDK_INT >= 31) {
                        RemoteViews(
                            mapOf(
                                SizeF(100f, 90f) to WidgetRenderer.build(ctx, model, wide = false),
                                SizeF(WIDE_MIN_DP, 90f) to WidgetRenderer.build(ctx, model, wide = true),
                            ),
                        )
                    } else {
                        val minW = mgr.getAppWidgetOptions(id)
                            ?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
                        WidgetRenderer.build(ctx, model, wide = minW == 0 || minW >= WIDE_MIN_DP)
                    }
                    mgr.updateAppWidget(id, views)
                } catch (_: Throwable) {
                    // Keep the previous rendering rather than crash the host.
                }
            }
            scheduleNextBoundary(ctx, model)
        }

        /**
         * Inexact, NON-wakeup alarm at the next routine block start (or just
         * after midnight) so "Next" and the day rollover stay right. It never
         * wakes the device: it is delivered the next time the screen is on.
         */
        private fun scheduleNextBoundary(ctx: Context, model: WidgetRenderer.Model) {
            try {
                val am = ctx.getSystemService(AlarmManager::class.java) ?: return
                val now = model.now
                val minute = now.hour * 60 + now.minute
                val midnight = now.toLocalDate().plusDays(1).atStartOfDay(now.zone).plusMinutes(1)
                val next = model.today()?.nextBlock(minute + 1)
                val at = if (next != null) {
                    now.toLocalDate().atStartOfDay(now.zone).plusMinutes(next.start.toLong())
                } else {
                    midnight
                }
                am.set(AlarmManager.RTC, at.toInstant().toEpochMilli(), SurfaceActions.refreshBroadcast(ctx))
            } catch (_: Throwable) {
            }
        }
    }
}
