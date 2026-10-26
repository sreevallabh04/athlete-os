package com.athleteos.athlete_os.assistant

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.athleteos.athlete_os.R

/**
 * Optional, user-started "Assistant mode": a low-priority foreground service
 * that keeps the app process (and with it the notification listener and,
 * while the activity is alive, the Flutter engine) running on an always-on
 * phone. It does no work of its own. ColorOS may still kill it unless the app
 * is exempted from battery optimisation and allowed to run in background.
 */
class AssistantForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP || intent?.action == ACTION_USER_STOP) {
            // Stop tapped on the notification: remember it so Flutter persists
            // "Assistant mode off" and does not restart the service on the next
            // launch. Programmatic stops (kill switch, in-app toggle) use
            // ACTION_STOP and leave the user's preference to Dart.
            if (intent?.action == ACTION_USER_STOP) markUserStop(this)
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        AssistantNotifications.ensureChannels(this)
        val stopIntent = PendingIntent.getService(
            this, 7101,
            Intent(this, AssistantForegroundService::class.java).setAction(ACTION_USER_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(this, AssistantNotifications.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle("Athlete OS assistant is running")
            .setContentText("Tap to open · Stop to end")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(AssistantNotifications.openAppIntent(this, 7100))
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_stat_notify), "Stop", stopIntent,
                ).build(),
            )
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (t: Throwable) {
            Log.w("AosAssistant", "foreground start failed: ${t.javaClass.simpleName}")
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        // Kill switch is authoritative natively too: a START_STICKY restart or
        // a stale start request must not bring Assistant mode back. Checked
        // after startForeground() so a startForegroundService() call never
        // ends without it (that crashes the process).
        val killed = try {
            AssistantConfig.load(this).killSwitch
        } catch (_: Throwable) {
            false
        }
        if (killed) {
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val ACTION_STOP = "com.athleteos.athlete_os.assistant.STOP"
        private const val ACTION_USER_STOP = "com.athleteos.athlete_os.assistant.USER_STOP"
        private const val NOTIFICATION_ID = 7100
        private const val PREFS = "athlete_os_assistant_service"
        private const val KEY_USER_STOPPED = "user_stopped"

        private fun prefs(ctx: Context) =
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun markUserStop(ctx: Context) {
            try {
                prefs(ctx).edit().putBoolean(KEY_USER_STOPPED, true).commit()
            } catch (_: Throwable) {
                // Best effort.
            }
        }

        /** True once after the user tapped Stop on the notification; clears the flag. */
        fun consumeUserStop(ctx: Context): Boolean = try {
            val p = prefs(ctx)
            val stopped = p.getBoolean(KEY_USER_STOPPED, false)
            if (stopped) p.edit().remove(KEY_USER_STOPPED).commit()
            stopped
        } catch (_: Throwable) {
            false
        }

        @Volatile
        var running: Boolean = false
            private set

        fun start(ctx: Context): Boolean = try {
            // An explicit start (in-app toggle / restore) supersedes an older Stop tap.
            try {
                prefs(ctx).edit().remove(KEY_USER_STOPPED).apply()
            } catch (_: Throwable) {
                // Best effort.
            }
            ctx.startForegroundService(Intent(ctx, AssistantForegroundService::class.java))
            true
        } catch (t: Throwable) {
            Log.w("AosAssistant", "service start failed: ${t.javaClass.simpleName}")
            false
        }

        fun stop(ctx: Context): Boolean = try {
            ctx.startService(Intent(ctx, AssistantForegroundService::class.java).setAction(ACTION_STOP))
            true
        } catch (_: Throwable) {
            ctx.stopService(Intent(ctx, AssistantForegroundService::class.java))
        }
    }
}
