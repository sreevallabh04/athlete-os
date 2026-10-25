package com.athleteos.athlete_os.assistant

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * Native copy of the assistant settings the notification listener needs.
 * Written by Flutter through `setConfig`; read on every posted notification
 * so a kill switch / disabled app takes effect immediately, even when the
 * Flutter engine is not running.
 *
 * Defaults are fail-closed: no package is allowed until Flutter writes one.
 */
data class AssistantConfig(
    val killSwitch: Boolean,
    val enabledPackages: Set<String>,
    val retentionDays: Int,
) {
    fun allows(packageName: String): Boolean =
        !killSwitch && enabledPackages.contains(packageName)

    companion object {
        private const val PREFS = "athlete_os_assistant"
        private const val KEY_KILL = "kill_switch"
        private const val KEY_PACKAGES = "enabled_packages"
        private const val KEY_RETENTION = "retention_days"

        private fun prefs(ctx: Context): SharedPreferences =
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun load(ctx: Context): AssistantConfig {
            val p = prefs(ctx)
            return AssistantConfig(
                killSwitch = p.getBoolean(KEY_KILL, false),
                enabledPackages = p.getStringSet(KEY_PACKAGES, emptySet())?.toSet() ?: emptySet(),
                retentionDays = p.getInt(KEY_RETENTION, 7),
            )
        }

        /** Parses `{"killSwitch":bool,"enabledPackages":[..],"retentionDays":n}`. */
        fun save(ctx: Context, json: String): AssistantConfig {
            val o = JSONObject(json)
            val arr = o.optJSONArray("enabledPackages")
            val pkgs = mutableSetOf<String>()
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val s = arr.optString(i)
                    if (s.isNotBlank()) pkgs.add(s)
                }
            }
            val cfg = AssistantConfig(
                killSwitch = o.optBoolean("killSwitch", false),
                enabledPackages = pkgs,
                retentionDays = o.optInt("retentionDays", 7).coerceIn(1, 90),
            )
            prefs(ctx).edit()
                .putBoolean(KEY_KILL, cfg.killSwitch)
                .putStringSet(KEY_PACKAGES, cfg.enabledPackages)
                .putInt(KEY_RETENTION, cfg.retentionDays)
                .apply()
            if (cfg.killSwitch) NotificationQueue.clear(ctx)
            return cfg
        }
    }
}
