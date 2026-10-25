package com.athleteos.athlete_os.assistant

import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.lang.ref.WeakReference

/**
 * Receives notifications posted by apps the user explicitly enabled in the
 * assistant settings. Everything else is ignored immediately (nothing is
 * read or stored). Never logs message content.
 */
class AssistantNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        current = WeakReference(this)
        Log.i(TAG, "listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        current = null
        Log.i(TAG, "listener disconnected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        try {
            val cfg = AssistantConfig.load(this)
            if (!cfg.allows(sbn.packageName)) return
            if (NotificationParser.shouldSkip(sbn, packageName)) return
            val parsed = NotificationParser.parse(sbn) ?: return
            val json = parsed.toJson()
            NotificationQueue.append(this, json)
            AssistantEvents.emit(json)
        } catch (t: Throwable) {
            // Metadata only: exception type, never content.
            Log.w(TAG, "capture failed: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        private const val TAG = "AosAssistant"

        @Volatile
        private var current: WeakReference<AssistantNotificationListener>? = null

        fun instance(): AssistantNotificationListener? = current?.get()
    }
}

/** Live stream of captured notifications to Flutter, when the engine is attached. */
object AssistantEvents : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun emit(json: String) {
        main.post {
            try {
                sink?.success(json)
            } catch (_: Throwable) {
                sink = null
            }
        }
    }
}
