package com.athleteos.athlete_os.assistant

import android.content.Context
import java.io.File

/**
 * Bounded on-disk queue (JSON lines in the app's private files dir) of
 * captured notifications, so nothing is lost while the Flutter engine is not
 * running. Drained (read + cleared) by Flutter on start/resume.
 *
 * Content lives only in app-private storage and is removed on drain, on
 * kill switch and on "delete all captured messages".
 */
object NotificationQueue {
    const val MAX_ENTRIES = 500
    private const val FILE_NAME = "assistant_queue.jsonl"
    private val lock = Any()

    private fun file(ctx: Context) = File(ctx.applicationContext.filesDir, FILE_NAME)

    fun append(ctx: Context, jsonLine: String) {
        synchronized(lock) {
            val f = file(ctx)
            val lines = if (f.exists()) f.readLines().filter { it.isNotBlank() }.toMutableList()
            else mutableListOf()
            lines.add(jsonLine.replace('\n', ' '))
            val kept = if (lines.size > MAX_ENTRIES) lines.takeLast(MAX_ENTRIES) else lines
            f.writeText(kept.joinToString("\n", postfix = "\n"))
        }
    }

    /** Returns every queued event and clears the queue. */
    fun drain(ctx: Context): List<String> {
        synchronized(lock) {
            val f = file(ctx)
            if (!f.exists()) return emptyList()
            val lines = f.readLines().filter { it.isNotBlank() }
            f.delete()
            return lines
        }
    }

    fun clear(ctx: Context) {
        synchronized(lock) { file(ctx).delete() }
    }

    fun size(ctx: Context): Int {
        synchronized(lock) {
            val f = file(ctx)
            return if (f.exists()) f.readLines().count { it.isNotBlank() } else 0
        }
    }
}
