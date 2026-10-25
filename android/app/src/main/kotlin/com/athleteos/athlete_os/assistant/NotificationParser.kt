package com.athleteos.athlete_os.assistant

import android.app.Notification
import android.app.Person
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.StatusBarNotification
import org.json.JSONObject

/** A messaging notification reduced to the fields the assistant needs. */
data class ParsedNotification(
    val key: String,
    val packageName: String,
    val conversationKey: String,
    val identityConfidence: String,
    val title: String?,
    val isGroup: Boolean,
    val sender: String?,
    val text: String,
    val postTime: Long,
    val hasReplyAction: Boolean,
    val dedupeHash: String,
) {
    fun toJson(): String = JSONObject().apply {
        put("key", key)
        put("packageName", packageName)
        put("conversationKey", conversationKey)
        put("identityConfidence", identityConfidence)
        put("title", title ?: JSONObject.NULL)
        put("isGroup", isGroup)
        put("sender", sender ?: JSONObject.NULL)
        put("text", text)
        put("postTime", postTime)
        put("hasReplyAction", hasReplyAction)
        put("dedupeHash", dedupeHash)
    }.toString()
}

/**
 * Extracts conversation data from a notification using only public APIs
 * (Notification extras / MessagingStyle bundles / actions). No scraping, no
 * private APIs, no accessibility service.
 */
object NotificationParser {
    private const val MAX_MESSAGES = 5
    private const val MAX_TEXT = 4000

    fun shouldSkip(sbn: StatusBarNotification, ownPackage: String): Boolean {
        val n = sbn.notification ?: return true
        if (sbn.packageName == ownPackage) return true
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return true
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return true
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return true
        return false
    }

    @Suppress("DEPRECATION")
    fun parse(sbn: StatusBarNotification): ParsedNotification? {
        val n = sbn.notification ?: return null
        val extras = n.extras ?: Bundle()

        val conversationTitle = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
        val plainTitle = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val title = (conversationTitle ?: plainTitle)?.takeIf { it.isNotBlank() }
        val isGroup = extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false)

        // MessagingStyle: Bundle[] under EXTRA_MESSAGES with keys text/time/sender/sender_person.
        var sender: String? = null
        var text: String? = null
        var time: Long = sbn.postTime
        val raw: Array<Parcelable>? = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (raw != null && raw.isNotEmpty()) {
            val msgs = raw.mapNotNull { it as? Bundle }.map { b ->
                val person = b.getParcelable<Person>("sender_person")
                Triple(
                    (person?.name ?: b.getCharSequence("sender"))?.toString(),
                    b.getCharSequence("text")?.toString(),
                    b.getLong("time", 0L),
                )
            }
            // Incoming messages after the user's own last message (sender null = self).
            val lastSelf = msgs.indexOfLast { it.first == null }
            val incoming = msgs.drop(lastSelf + 1).filter { !it.second.isNullOrBlank() }
            if (incoming.isNotEmpty()) {
                val latest = incoming.takeLast(MAX_MESSAGES)
                sender = latest.last().first
                text = latest.joinToString("\n") { it.second!! }
                val t = latest.last().third
                if (t > 0) time = t
            } else if (msgs.isNotEmpty()) {
                // Only the user's own messages: nothing to reply to.
                return null
            }
        }
        if (text.isNullOrBlank()) {
            text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()
            if (sender == null && !isGroup) sender = plainTitle
            // sbn.postTime changes every time the app re-posts/updates the
            // notification, which would defeat the dedupe hash. The app-set
            // `when` (event time) is stable across re-posts.
            if (n.`when` > 0) time = n.`when`
        }
        if (text.isNullOrBlank()) return null
        val body = if (text.length > MAX_TEXT) text.substring(0, MAX_TEXT) else text

        var conversationKey: String? = n.shortcutId?.takeIf { it.isNotBlank() }
        if (conversationKey == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            conversationKey = n.locusId?.id?.takeIf { it.isNotBlank() }
        }
        val confidence = if (conversationKey != null) "high" else "low"
        if (conversationKey == null) conversationKey = "title:" + (title ?: "unknown")

        val hash = dedupeHash(sbn.packageName, conversationKey, body, time)
        return ParsedNotification(
            key = sbn.key,
            packageName = sbn.packageName,
            conversationKey = conversationKey,
            identityConfidence = confidence,
            title = title,
            isGroup = isGroup,
            sender = sender,
            text = body,
            postTime = time,
            hasReplyAction = findReplyAction(n) != null,
            dedupeHash = hash,
        )
    }

    /**
     * The notification's own inline-reply action: an action with a free-form
     * RemoteInput, preferring SEMANTIC_ACTION_REPLY. Falls back to the
     * wearable-extender actions (what smartwatches use).
     */
    @Suppress("DEPRECATION")
    fun findReplyAction(n: Notification): Notification.Action? {
        fun candidates(actions: List<Notification.Action>) = actions.filter { a ->
            a.actionIntent != null && a.remoteInputs?.any { it.allowFreeFormInput } == true
        }
        val direct = candidates(n.actions?.toList() ?: emptyList())
        direct.firstOrNull { it.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY }
            ?.let { return it }
        direct.firstOrNull()?.let { return it }
        val wear = try {
            candidates(Notification.WearableExtender(n).actions ?: emptyList())
        } catch (_: Throwable) {
            emptyList()
        }
        return wear.firstOrNull { it.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY }
            ?: wear.firstOrNull()
    }

    /**
     * FNV-1a 64-bit over "package|conversation|text|seconds". Mirrored in
     * Dart (`dedupeHashFor`) so both sides agree.
     */
    fun dedupeHash(pkg: String, conversationKey: String, text: String, timeMs: Long): String {
        val input = "$pkg|$conversationKey|$text|${timeMs / 1000}"
        var h = 0xcbf29ce484222325uL.toLong()
        val prime = 0x100000001b3L
        for (b in input.toByteArray(Charsets.UTF_8)) {
            h = h xor (b.toLong() and 0xff)
            h *= prime
        }
        return java.lang.Long.toUnsignedString(h, 16).padStart(16, '0')
    }
}
