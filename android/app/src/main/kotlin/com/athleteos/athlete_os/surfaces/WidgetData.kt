package com.athleteos.athlete_os.surfaces

import org.json.JSONObject

/** One value vs target. [value] is null when nothing was logged/synced. */
data class WidgetMetric(val value: Double?, val target: Double?)

data class WidgetBlock(val start: Int, val end: Int, val title: String, val kind: String)

/**
 * Parsed widget snapshot (wire format v1, written by
 * lib/features/surfaces/domain/widget_snapshot.dart). Missing or malformed
 * fields become null — the renderer shows "—" rather than guessing.
 */
data class WidgetData(
    val date: String,
    val updatedAt: Long,
    val steps: WidgetMetric,
    val protein: WidgetMetric,
    val calories: WidgetMetric,
    val water: WidgetMetric,
    val sessionTitle: String?,
    val sessionDone: Boolean,
    val routine: List<WidgetBlock>,
) {
    companion object {
        private fun JSONObject.numOrNull(key: String): Double? =
            if (!has(key) || isNull(key)) null else optDouble(key).takeIf { !it.isNaN() && !it.isInfinite() }

        private fun metric(root: JSONObject, key: String): WidgetMetric {
            val o = root.optJSONObject(key) ?: return WidgetMetric(null, null)
            return WidgetMetric(o.numOrNull("v"), o.numOrNull("t")?.takeIf { it > 0 })
        }

        fun parse(raw: String): WidgetData? = try {
            val o = JSONObject(raw)
            val session = o.optJSONObject("session")
            val blocks = o.optJSONArray("routine")
            val routine = ArrayList<WidgetBlock>()
            if (blocks != null) {
                for (i in 0 until blocks.length()) {
                    val b = blocks.optJSONObject(i) ?: continue
                    val title = b.optString("t").trim()
                    if (title.isEmpty()) continue
                    routine.add(WidgetBlock(b.optInt("s"), b.optInt("e"), title, b.optString("k")))
                }
            }
            routine.sortBy { it.start }
            WidgetData(
                date = o.optString("date"),
                updatedAt = o.optLong("updatedAt"),
                steps = metric(o, "steps"),
                protein = metric(o, "protein"),
                calories = metric(o, "calories"),
                water = metric(o, "water"),
                sessionTitle = session?.optString("title")?.trim()?.takeIf { it.isNotEmpty() && it != "null" },
                sessionDone = session?.optBoolean("done") ?: false,
                routine = routine,
            )
        } catch (_: Throwable) {
            null
        }
    }

    /** First block starting at or after [minuteOfDay]. */
    fun nextBlock(minuteOfDay: Int): WidgetBlock? = routine.firstOrNull { it.start >= minuteOfDay }

    /** Block in progress at [minuteOfDay]. */
    fun currentBlock(minuteOfDay: Int): WidgetBlock? =
        routine.lastOrNull { it.start <= minuteOfDay && minuteOfDay < it.end }
}
