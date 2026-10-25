package com.athleteos.athlete_os.assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.athleteos.athlete_os.MainActivity
import com.athleteos.athlete_os.R

/** Notification channels + posting for assistant briefings and approvals. */
object AssistantNotifications {
    const val CHANNEL_SERVICE = "assistant_service"
    const val CHANNEL_BRIEFING = "assistant_briefing"

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SERVICE, "Assistant mode", NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Persistent notice while Assistant mode keeps the app running."
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_BRIEFING, "Assistant briefings & approvals", NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Morning briefing, evening review and replies waiting for your approval."
            },
        )
    }

    fun openAppIntent(ctx: Context, requestCode: Int): PendingIntent {
        val intent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_OPEN_ROUTE, "/assistant")
        }
        return PendingIntent.getActivity(
            ctx, requestCode, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun post(ctx: Context, id: Int, title: String, body: String): Boolean {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false
        if (!nm.areNotificationsEnabled()) return false
        ensureChannels(ctx)
        val n = Notification.Builder(ctx, CHANNEL_BRIEFING)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(ctx, 7000 + (id and 0xff)))
            .build()
        return try {
            nm.notify(id, n)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun enabled(ctx: Context): Boolean =
        ctx.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() ?: false
}
