package com.athleteos.athlete_os.assistant

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import java.util.Collections

/**
 * Hands a user-approved reply to the source app's own notification reply
 * action (RemoteInput) — the same mechanism smartwatches and Android Auto
 * use. The source app does not report delivery, so success is reported as
 * `handed_off`, never "sent"/"delivered".
 */
object ReplySender {
    private const val TAG = "AosAssistant"

    /** Idempotency keys already handed off in this process. */
    private val usedKeys: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    fun send(ctx: Context, notificationKey: String, text: String, idempotencyKey: String): Map<String, Any?> {
        if (text.isBlank()) return result("failed", "empty_text", "The reply is empty.")
        if (idempotencyKey.isBlank()) return result("failed", "missing_idempotency_key", "Missing idempotency key.")
        if (usedKeys.contains(idempotencyKey)) {
            return result("failed", "duplicate", "This reply was already handed off once; it is never sent twice.")
        }
        val listener = AssistantNotificationListener.instance()
            ?: return result(
                "failed", "listener_not_connected",
                "Notification access is off or the listener is not connected yet.",
            )
        val sbn = try {
            listener.activeNotifications?.firstOrNull { it.key == notificationKey }
        } catch (_: Throwable) {
            return result("failed", "listener_not_connected", "The notification listener is not connected.")
        } ?: return result(
            "failed", "notification_gone",
            "The original notification is no longer showing (dismissed, read or replaced). Open the app to reply.",
        )
        val action = NotificationParser.findReplyAction(sbn.notification)
            ?: return result("unsupported", "no_reply_action", "This notification has no reply action.")
        val inputs = action.remoteInputs?.filter { it.allowFreeFormInput }.orEmpty()
        if (inputs.isEmpty()) {
            return result("unsupported", "no_reply_action", "This notification has no free-text reply input.")
        }

        val label = appLabel(ctx, sbn.packageName)
        val fill = Intent()
        val bundle = Bundle()
        for (ri in inputs) bundle.putCharSequence(ri.resultKey, text)
        RemoteInput.addResultsToIntent(inputs.toTypedArray(), fill, bundle)
        RemoteInput.setResultsSource(fill, RemoteInput.SOURCE_FREE_FORM_INPUT)

        // Mark used before sending so a crash/retry can never double-send.
        usedKeys.add(idempotencyKey)
        return try {
            action.actionIntent.send(ctx, 0, fill)
            Log.i(TAG, "reply handed off")
            result(
                "handed_off", "handed_off",
                "Handed to $label's reply action; the app does not confirm delivery",
            )
        } catch (_: PendingIntent.CanceledException) {
            result(
                "failed", "pending_intent_cancelled",
                "$label cancelled its reply action (the notification was probably updated). Open the app to reply.",
            )
        } catch (t: Throwable) {
            Log.w(TAG, "reply failed: ${t.javaClass.simpleName}")
            result("failed", "send_error", "$label rejected the reply action (${t.javaClass.simpleName}).")
        }
    }

    fun appLabel(ctx: Context, pkg: String): String = try {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        pkg
    } catch (_: Throwable) {
        pkg
    }

    private fun result(status: String, code: String, detail: String) =
        mapOf("status" to status, "code" to code, "detail" to detail)
}
