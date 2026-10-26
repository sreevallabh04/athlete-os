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

    /**
     * Briefings / evening reviews / approvals. A new id because a channel's
     * lock-screen visibility can only be set before it is first created; the
     * pre-privacy channel is deleted in [ensureChannels].
     */
    const val CHANNEL_BRIEFING = "assistant_briefing_private"
    private const val LEGACY_CHANNEL_BRIEFING = "assistant_briefing"

    private const val DEFAULT_PUBLIC_TITLE = "JARVIS"
    private const val DEFAULT_PUBLIC_BODY = "Unlock to view"

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
                // Details only when unlocked; the lock screen gets the generic public version.
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
        try {
            nm.deleteNotificationChannel(LEGACY_CHANNEL_BRIEFING)
        } catch (_: Throwable) {
            // Best effort.
        }
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

    /**
     * Posts a briefing / approval notification. Private unless [isPublic]:
     * on a secure lock screen only the generic [publicTitle] / [publicBody]
     * version is shown (never contact names, app names or health numbers).
     */
    fun post(
        ctx: Context,
        id: Int,
        title: String,
        body: String,
        isPublic: Boolean = false,
        publicTitle: String? = null,
        publicBody: String? = null,
    ): Boolean {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false
        if (!nm.areNotificationsEnabled()) return false
        ensureChannels(ctx)
        val contentIntent = openAppIntent(ctx, 7000 + (id and 0xff))
        val builder = Notification.Builder(ctx, CHANNEL_BRIEFING)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
        if (isPublic) {
            builder.setVisibility(Notification.VISIBILITY_PUBLIC)
        } else {
            val redacted = Notification.Builder(ctx, CHANNEL_BRIEFING)
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentTitle(publicTitle?.takeIf { it.isNotBlank() } ?: DEFAULT_PUBLIC_TITLE)
                .setContentText(publicBody?.takeIf { it.isNotBlank() } ?: DEFAULT_PUBLIC_BODY)
                .setContentIntent(contentIntent)
                .build()
            builder.setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(redacted)
        }
        val n = builder.build()
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
