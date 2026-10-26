package com.athleteos.athlete_os.assistant

import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Registers the assistant's platform channels:
 *  * MethodChannel `athlete_os/assistant`
 *  * EventChannel  `athlete_os/notifications/events`
 *  * MethodChannel `athlete_os/health_connect` (openSettings)
 *  * MethodChannel `athlete_os/share` + EventChannel `athlete_os/share/events`
 */
class AssistantChannels(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newSingleThreadExecutor()
    private val ctx get() = activity.applicationContext

    fun register(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "athlete_os/assistant").setMethodCallHandler(this)
        EventChannel(messenger, "athlete_os/notifications/events").setStreamHandler(AssistantEvents)
        MethodChannel(messenger, "athlete_os/health_connect").setMethodCallHandler { call, result ->
            if (call.method == "openSettings") result.success(openHealthConnectSettings())
            else result.notImplemented()
        }
        MethodChannel(messenger, "athlete_os/share").setMethodCallHandler { call, result ->
            if (call.method == "getInitialShare") result.success(ShareIntake.takeInitial())
            else result.notImplemented()
        }
        EventChannel(messenger, "athlete_os/share/events").setStreamHandler(ShareIntake)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isListenerEnabled" -> result.success(isListenerEnabled())
                "isListenerConnected" -> result.success(AssistantNotificationListener.instance() != null)
                "openListenerSettings" -> result.success(openListenerSettings())
                "setConfig" -> {
                    val json = call.argument<String>("json") ?: "{}"
                    io.execute {
                        val ok = try {
                            AssistantConfig.save(ctx, json); true
                        } catch (_: Throwable) {
                            false
                        }
                        activity.runOnUiThread { result.success(ok) }
                    }
                }
                "drainQueue" -> io.execute {
                    val lines = try { NotificationQueue.drain(ctx) } catch (_: Throwable) { emptyList() }
                    activity.runOnUiThread { result.success(lines) }
                }
                "clearQueue" -> io.execute {
                    NotificationQueue.clear(ctx)
                    activity.runOnUiThread { result.success(true) }
                }
                "sendReply" -> {
                    val key = call.argument<String>("notificationKey") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    val idem = call.argument<String>("idempotencyKey") ?: ""
                    result.success(ReplySender.send(ctx, key, text, idem))
                }
                "openApp" -> {
                    val pkg = call.argument<String>("packageName") ?: ""
                    val launch = activity.packageManager.getLaunchIntentForPackage(pkg)
                    if (launch == null) result.success(false)
                    else result.success(start(launch))
                }
                "listLaunchableApps" -> io.execute {
                    val apps = try { listLaunchableApps() } catch (_: Throwable) { emptyList() }
                    activity.runOnUiThread { result.success(apps) }
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = activity.getSystemService(PowerManager::class.java)
                    result.success(pm?.isIgnoringBatteryOptimizations(activity.packageName) ?: false)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    val direct = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${activity.packageName}"),
                    )
                    result.success(start(direct) || start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
                }
                "openAppDetailsSettings" -> result.success(
                    start(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${activity.packageName}"),
                        ),
                    ),
                )
                "openNotificationSettings" -> result.success(
                    start(
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
                    ),
                )
                "areNotificationsEnabled" -> result.success(AssistantNotifications.enabled(ctx))
                "canScheduleExactAlarms" -> {
                    val am = activity.getSystemService(AlarmManager::class.java)
                    result.success(if (Build.VERSION.SDK_INT >= 31) am?.canScheduleExactAlarms() ?: false else true)
                }
                "startAssistantService" -> result.success(AssistantForegroundService.start(ctx))
                "stopAssistantService" -> result.success(AssistantForegroundService.stop(ctx))
                "isAssistantServiceRunning" -> result.success(AssistantForegroundService.running)
                "postNotification" -> {
                    val id = call.argument<Int>("id") ?: 7200
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    // Private unless Dart explicitly asks for public (fail closed).
                    val isPublic = call.argument<String>("visibility") == "public"
                    result.success(
                        AssistantNotifications.post(
                            ctx, id, title, body,
                            isPublic = isPublic,
                            publicTitle = call.argument<String>("publicTitle"),
                            publicBody = call.argument<String>("publicBody"),
                        ),
                    )
                }
                "consumeServiceStopRequest" ->
                    result.success(AssistantForegroundService.consumeUserStop(ctx))
                "openHealthConnectSettings" -> result.success(openHealthConnectSettings())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Error code only; never echo arguments (they may contain message text).
            result.error("assistant_error", t.javaClass.simpleName, null)
        }
    }

    private fun start(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }

    private fun listenerComponent() = ComponentName(activity, AssistantNotificationListener::class.java)

    private fun isListenerEnabled(): Boolean {
        val nm = activity.getSystemService(NotificationManager::class.java) ?: return false
        return try {
            nm.isNotificationListenerAccessGranted(listenerComponent())
        } catch (_: Throwable) {
            val flat = Settings.Secure.getString(activity.contentResolver, "enabled_notification_listeners") ?: ""
            flat.contains(listenerComponent().flattenToString())
        }
    }

    private fun openListenerSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= 30) {
            val detail = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(
                    Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                    listenerComponent().flattenToString(),
                )
            if (start(detail)) return true
        }
        return start(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    @Suppress("DEPRECATION")
    private fun listLaunchableApps(): List<Map<String, String>> {
        val pm = activity.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val infos = if (Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
        } else {
            pm.queryIntentActivities(intent, 0)
        }
        return infos
            .map { mapOf("packageName" to it.activityInfo.packageName, "label" to it.loadLabel(pm).toString()) }
            .filter { it["packageName"] != activity.packageName }
            .distinctBy { it["packageName"] }
            .sortedBy { it["label"]?.lowercase() }
    }

    /**
     * Opens Health Connect. Returns which route worked:
     * `hc_settings_action` | `platform_home_settings` | `hc_app` |
     * `play_store` | `play_store_web` | null.
     */
    private fun openHealthConnectSettings(): String? {
        val pkg = "com.google.android.apps.healthdata"
        val attempts = listOf<Pair<String, () -> Intent?>>(
            "hc_settings_action" to { Intent("androidx.health.ACTION_HEALTH_CONNECT_SETTINGS") },
            "platform_home_settings" to { Intent("android.health.connect.action.HEALTH_HOME_SETTINGS") },
            "hc_app" to { activity.packageManager.getLaunchIntentForPackage(pkg) },
            "play_store" to { Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg")) },
            "play_store_web" to {
                Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg"))
            },
        )
        for ((name, build) in attempts) {
            val intent = try { build() } catch (_: Throwable) { null } ?: continue
            if (start(intent)) return name
        }
        return null
    }
}
