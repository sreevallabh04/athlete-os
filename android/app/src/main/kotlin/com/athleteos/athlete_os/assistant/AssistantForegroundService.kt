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
        if (intent?.action == ACTION_STOP) {
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        AssistantNotifications.ensureChannels(this)
        val stopIntent = PendingIntent.getService(
            this, 7101,
            Intent(this, AssistantForegroundService::class.java).setAction(ACTION_STOP),
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
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val ACTION_STOP = "com.athleteos.athlete_os.assistant.STOP"
        private const val NOTIFICATION_ID = 7100

        @Volatile
        var running: Boolean = false
            private set

        fun start(ctx: Context): Boolean = try {
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
