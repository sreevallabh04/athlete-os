package com.athleteos.athlete_os.surfaces

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Small native store shared by the home-screen surfaces (private
 * SharedPreferences, no other app can read it):
 *
 *  * `snapshot` — the latest widget snapshot JSON pushed by Flutter
 *    (`WidgetSnapshot.encode()` in lib/features/surfaces/domain).
 *  * `water_queue` — water taps from the widget / Quick Settings tile that
 *    Flutter has not stored yet. Flutter peeks, stores each entry with a
 *    stable row id (idempotent) and only then acks, so nothing is lost if
 *    the process dies in between and nothing is logged twice.
 */
object SurfaceStore {
    private const val PREFS = "athlete_os_surfaces"
    private const val KEY_SNAPSHOT = "snapshot"
    private const val KEY_QUEUE = "water_queue"
    private const val MAX_QUEUE = 200
    private const val MAX_SNAPSHOT_CHARS = 64_000

    private val lock = Any()

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun saveSnapshot(ctx: Context, json: String): Boolean {
        if (json.length > MAX_SNAPSHOT_CHARS) return false
        // Validate before storing so a bad push can never break rendering.
        try {
            JSONObject(json)
        } catch (_: Throwable) {
            return false
        }
        return prefs(ctx).edit().putString(KEY_SNAPSHOT, json).commit()
    }

    fun snapshot(ctx: Context): WidgetData? {
        val raw = prefs(ctx).getString(KEY_SNAPSHOT, null) ?: return null
        return WidgetData.parse(raw)
    }

    /** Appends a water tap; returns its id. */
    fun enqueueWater(ctx: Context, ml: Int, source: String, atMillis: Long = System.currentTimeMillis()): String {
        val id = "w-" + UUID.randomUUID().toString()
        synchronized(lock) {
            val arr = readQueue(ctx)
            arr.put(
                JSONObject()
                    .put("id", id)
                    .put("ml", ml)
                    .put("at", atMillis)
                    .put("source", source),
            )
            // Bounded: drop the oldest beyond the cap.
            val trimmed = if (arr.length() > MAX_QUEUE) {
                JSONArray().also { out ->
                    for (i in arr.length() - MAX_QUEUE until arr.length()) out.put(arr.get(i))
                }
            } else {
                arr
            }
            prefs(ctx).edit().putString(KEY_QUEUE, trimmed.toString()).commit()
        }
        return id
    }

    /** Pending entries as maps for the MethodChannel (not removed). */
    fun peekWater(ctx: Context): List<Map<String, Any?>> = synchronized(lock) {
        val arr = readQueue(ctx)
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            mapOf(
                "id" to o.optString("id"),
                "ml" to o.optInt("ml"),
                "at" to o.optLong("at"),
                "source" to o.optString("source"),
            )
        }
    }

    /** Removes the given ids (entries Flutter stored or rejected). */
    fun ackWater(ctx: Context, ids: Collection<String>) {
        if (ids.isEmpty()) return
        val set = ids.toHashSet()
        synchronized(lock) {
            val arr = readQueue(ctx)
            val out = JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (!set.contains(o.optString("id"))) out.put(o)
            }
            prefs(ctx).edit().putString(KEY_QUEUE, out.toString()).commit()
        }
    }

    /**
     * Water (ml) tapped on a surface after [sinceMillis] and on or after
     * [dayStartMillis] that Flutter has not stored yet — shown on the widget
     * so a tap is reflected immediately even when the app is not running.
     */
    fun pendingWaterMl(ctx: Context, sinceMillis: Long, dayStartMillis: Long): Int = synchronized(lock) {
        val arr = readQueue(ctx)
        var total = 0
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val at = o.optLong("at")
            if (at > sinceMillis && at >= dayStartMillis) total += o.optInt("ml")
        }
        total
    }

    private fun readQueue(ctx: Context): JSONArray {
        val raw = prefs(ctx).getString(KEY_QUEUE, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (_: Throwable) {
            JSONArray()
        }
    }
}
