package com.athleteos.athlete_os.surfaces

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Bridges surface events to Flutter over `athlete_os/surfaces/events`:
 *
 *  * `{"type":"link","uri":"athleteos://open/..."}` — a deep link that opened
 *    MainActivity (widget section, launcher shortcut, other app). Only the
 *    `open` host is accepted here; `athleteos://localhost/...` belongs to the
 *    OAuth callbacks and is never touched. Flutter validates the path against
 *    its allowlist (lib/features/surfaces/domain/deep_links.dart).
 *  * `{"type":"water_queued"}` — the widget/tile queued water; Flutter drains
 *    the native queue right away.
 *
 * When Flutter is not listening yet (cold start), the link is kept as
 * pending and returned by `getInitialLink`.
 */
object SurfaceEvents : EventChannel.StreamHandler {
    const val SCHEME = "athleteos"
    const val HOST = "open"
    private const val MAX_URI = 512

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var pendingLink: String? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    /** True while a Dart listener is attached (engine running). */
    val attached: Boolean get() = sink != null

    /** Returns true when the intent carried an `athleteos://open/...` link. */
    fun handleIntent(intent: Intent?): Boolean {
        val data = intent?.data ?: return false
        if (intent.action != Intent.ACTION_VIEW) return false
        if (!data.scheme.equals(SCHEME, ignoreCase = true)) return false
        if (!data.host.equals(HOST, ignoreCase = true)) return false
        val uri = data.toString()
        if (uri.length > MAX_URI) return false
        // Consume so a configuration change / recreation does not re-open it.
        intent.data = null
        val s = sink
        if (s != null) {
            main.post { s.success(mapOf("type" to "link", "uri" to uri)) }
        } else {
            pendingLink = uri
        }
        return true
    }

    fun takeInitialLink(): String? {
        val l = pendingLink
        pendingLink = null
        return l
    }

    /** Tells a running Flutter engine that the water queue changed. */
    fun notifyWaterQueued() {
        val s = sink ?: return
        main.post { s.success(mapOf("type" to "water_queued")) }
    }

    /** Called when the engine is torn down (MainActivity.cleanUpFlutterEngine). */
    fun detach() {
        sink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
