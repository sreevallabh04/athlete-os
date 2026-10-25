package com.athleteos.athlete_os.surfaces

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import com.athleteos.athlete_os.MainActivity

/** Shared PendingIntents and the one water action used by every surface. */
object SurfaceActions {
    const val ACTION_LOG_WATER = "com.athleteos.athlete_os.surfaces.LOG_WATER"
    const val ACTION_REFRESH = "com.athleteos.athlete_os.surfaces.REFRESH"
    const val EXTRA_SOURCE = "source"

    /** Fixed amount for one widget / tile tap (labelled "+250 ml"). */
    const val WATER_ML = 250

    private const val DOUBLE_FIRE_GUARD_MS = 700L

    @Volatile
    private var lastWaterAt = 0L

    /** Explicit MainActivity intent for `athleteos://open/<path>`. */
    fun openLink(ctx: Context, path: String, requestCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("${SurfaceEvents.SCHEME}://${SurfaceEvents.HOST}/$path"))
            .setClass(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            ctx, requestCode, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun logWaterBroadcast(ctx: Context, source: String, requestCode: Int): PendingIntent {
        val intent = Intent(ctx, SurfaceActionReceiver::class.java)
            .setAction(ACTION_LOG_WATER)
            .putExtra(EXTRA_SOURCE, source)
        return PendingIntent.getBroadcast(
            ctx, requestCode, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun refreshBroadcast(ctx: Context): PendingIntent {
        val intent = Intent(ctx, SurfaceActionReceiver::class.java).setAction(ACTION_REFRESH)
        return PendingIntent.getBroadcast(
            ctx, 7301, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /**
     * Queues +250 ml (durable), tells a running Flutter engine to store it now
     * and re-renders the widget so the tap shows immediately. Returns false
     * when ignored as an accidental double fire.
     */
    fun logWater(ctx: Context, source: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastWaterAt < DOUBLE_FIRE_GUARD_MS) return false
        lastWaterAt = now
        val safeSource = if (source == "qs_tile") "qs_tile" else "widget"
        SurfaceStore.enqueueWater(ctx, WATER_ML, safeSource)
        SurfaceEvents.notifyWaterQueued()
        JarvisTodayWidget.updateAll(ctx)
        return true
    }
}

/** Not exported: only our own PendingIntents (widget, alarms) reach it. */
class SurfaceActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            when (intent.action) {
                SurfaceActions.ACTION_LOG_WATER -> SurfaceActions.logWater(
                    context,
                    intent.getStringExtra(SurfaceActions.EXTRA_SOURCE) ?: "widget",
                )
                SurfaceActions.ACTION_REFRESH -> JarvisTodayWidget.updateAll(context)
            }
        } catch (_: Throwable) {
            // Never crash the launcher's broadcast; the next update retries.
        }
    }
}
