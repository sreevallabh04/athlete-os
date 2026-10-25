package com.athleteos.athlete_os.surfaces

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Registers the home-screen surfaces' platform channels:
 *  * MethodChannel `athlete_os/surfaces`: getInitialLink, peekWaterQueue,
 *    ackWaterQueue, updateWidget
 *  * EventChannel  `athlete_os/surfaces/events` ([SurfaceEvents])
 */
class SurfacesChannels(context: Context) {
    private val ctx = context.applicationContext
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "athlete_os/surfaces/events").setStreamHandler(SurfaceEvents)
        MethodChannel(messenger, "athlete_os/surfaces").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getInitialLink" -> result.success(SurfaceEvents.takeInitialLink())
                    "peekWaterQueue" -> io.execute {
                        val items = try { SurfaceStore.peekWater(ctx) } catch (_: Throwable) { emptyList() }
                        main.post { result.success(items) }
                    }
                    "ackWaterQueue" -> {
                        val ids = call.argument<List<String>>("ids") ?: emptyList()
                        io.execute {
                            val ok = try { SurfaceStore.ackWater(ctx, ids); true } catch (_: Throwable) { false }
                            main.post { result.success(ok) }
                        }
                    }
                    "updateWidget" -> {
                        val json = call.argument<String>("json") ?: ""
                        io.execute {
                            val ok = try {
                                SurfaceStore.saveSnapshot(ctx, json).also { saved ->
                                    if (saved) JarvisTodayWidget.updateAll(ctx)
                                }
                            } catch (_: Throwable) {
                                false
                            }
                            main.post { result.success(ok) }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("surfaces_error", t.javaClass.simpleName, null)
            }
        }
    }
}
