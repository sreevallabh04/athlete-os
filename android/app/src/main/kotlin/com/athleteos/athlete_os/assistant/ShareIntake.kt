package com.athleteos.athlete_os.assistant

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Text shared into the app (ACTION_SEND text/plain) and in-app routes
 * requested by assistant notifications. Delivered to Flutter via
 * `athlete_os/share` (`getInitialShare`) and `athlete_os/share/events`.
 *
 * Payloads: {"type":"share","text":"..."} or {"type":"route","route":"/assistant"}.
 */
object ShareIntake : EventChannel.StreamHandler {
    private const val MAX_TEXT = 8000
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var pending: Map<String, Any?>? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    /** Returns true when the intent carried something for Flutter. */
    fun handle(intent: Intent?, routeExtra: String): Boolean {
        if (intent == null) return false
        val payload: Map<String, Any?>? = when {
            intent.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                if (text.isNullOrBlank()) null
                else mapOf("type" to "share", "text" to text.take(MAX_TEXT))
            }
            intent.hasExtra(routeExtra) -> {
                val route = intent.getStringExtra(routeExtra)
                if (route.isNullOrBlank() || !route.startsWith("/")) null
                else mapOf("type" to "route", "route" to route)
            }
            else -> null
        } ?: return false
        // Consume so a configuration change does not re-deliver it.
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(routeExtra)
        val s = sink
        if (s != null) {
            main.post { s.success(payload) }
        } else {
            pending = payload
        }
        return true
    }

    /** Returns and clears the share/route that launched the app, if any. */
    fun takeInitial(): Map<String, Any?>? {
        val p = pending
        pending = null
        return p
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
