# Messaging assistant ("personal AI agent phone")

Athlete OS can turn a spare, always-on Android phone (target: OPPO CPH2251,
Android 13 / ColorOS) into a personal assistant that watches messaging
notifications, prepares reply drafts, and hands replies to the messaging app
**only when you tap Send** (or, for SMS apps you explicitly allow, under strict
"restricted auto-reply" rules).

Code: `lib/features/assistant/**` (Dart) and
`android/app/src/main/kotlin/com/athleteos/athlete_os/assistant/**` (Kotlin).

## How it works

1. `AssistantNotificationListener` (a `NotificationListenerService`) receives
   every posted notification. It immediately ignores anything that is not from
   an app **you enabled** (allowlist mirrored to native SharedPreferences by
   Flutter via `setConfig`) or when the **kill switch** is on. Ongoing,
   foreground-service, group-summary and own-app notifications are skipped.
2. For allowed apps it extracts (public APIs only): conversation title,
   `isGroup`, latest incoming message(s) + sender from the `MessagingStyle`
   bundles, conversation key (shortcut id / locus id → identity confidence
   **high**; otherwise the title → **low**) and whether a free-text
   RemoteInput reply action exists (prefers `SEMANTIC_ACTION_REPLY`, falls back
   to wearable-extender actions).
3. Each event is appended to a bounded native queue (JSON lines in the app's
   private files dir, max 500, oldest dropped) and streamed live over
   `athlete_os/notifications/events` when the Flutter engine is attached.
   Flutter drains the queue on start, on resume and a few seconds after live
   events.
4. Dart ingestion (`IngestionService`): kill switch → per-app settings →
   contact rules → **local `SensitivityClassifier`** (before any AI) →
   **`ReplyPolicyEngine`** → `insertOrIgnore` on the dedupe hash → draft →
   (optional) AI draft → (only if allowed) send. Every decision is audited
   without content.

## Capability matrix

Observing always means "via the app's notifications" — previews, not the full
chat history. "Reply" means the notification's own RemoteInput reply action.

| App | Package | Observe | Reply via notification | Auto-reply | Why |
| --- | --- | --- | --- | --- | --- |
| WhatsApp | `com.whatsapp` | Yes | Yes (exposes Reply; verify on device) | **Blocked in code** | WhatsApp ToS prohibit "bulk messaging, auto-messaging, auto-dialing" and access "through automated means". Send happens only on your tap of a specific draft. |
| WhatsApp Business | `com.whatsapp.w4b` | Yes | Yes (unverified) | **Blocked in code** | Same ToS. The WhatsApp Business Platform (Cloud API) cannot attach to an existing personal number (the number must leave the consumer app; history is lost) — not applicable. |
| Google Messages | `com.google.android.apps.messaging` | Yes | Yes (unverified) | Allowed under restricted rules | Plain SMS/RCS on your own number; Android itself ships auto-reply features. |
| Messages (AOSP/ColorOS) | `com.android.mms` | Yes | Unverified | Allowed under restricted rules | SMS. |
| Telegram | `org.telegram.messenger` | Yes | Yes (unverified) | Blocked (unverified terms) | Could not verify terms for automated replies from a personal account. |
| Signal | `org.thoughtcrime.securesms` | Yes | Yes (unverified) | Blocked (unverified terms) | Same. |
| Gmail | `com.google.android.gm` | Yes (subject/snippet) | Usually no free-text reply action | Blocked (unverified terms) | Use Copy & open. |
| Slack | `com.Slack` | Yes | Yes (unverified) | Blocked (unverified terms) | Workspace policies vary. |
| Instagram | `com.instagram.android` | Yes | Yes for DMs (unverified) | Blocked (unverified terms) | Meta terms restrict automation. |
| Any other app | — | Yes, if you add it | Depends on the app | Blocked (unverified) | Default block for anything we cannot verify. |

"Unverified" = not yet tested on the OPPO; the app may or may not expose a
RemoteInput action. When there is none, the draft shows **Copy & open**
(copies the text, opens the app; status `unsupported` with an explanation).

`autoSendBlocked` is derived from code (`isAutoSendBlockedInCode`) every time
an app row is written; settings cannot lift it, and the policy engine checks
the code-level block again independently.

## Modes

Global mode (default **Draft**) caps every app's mode (effective mode = the
lower of the two). All per-app enables default to **off**.

| Mode | Effect |
| --- | --- |
| Disabled | Nothing captured, drafted or sent. |
| Observe | Messages captured; summaries only; no drafts. |
| Draft (default) | Drafts saved. Nothing is sent unless you tap Send. |
| Approval | Drafts flagged "Needs approval" + a content-free notification (private on the lock screen: "JARVIS · New message to review"). Sent only when you tap Send. |
| Restricted auto-reply | Auto-send **only** if every rule below passes; otherwise downgraded to Approval with the failing reasons. |

## Safety rules (enforced in `ReplyPolicyEngine`, never in AI prompts)

Ignore (store nothing): kill switch on, global mode Disabled, app not enabled
or Disabled, conversation blocked, group chat not explicitly approved (only the
group's name is kept so you can approve it).

Restricted auto-reply requires ALL of:
- app not auto-send-blocked (never WhatsApp / WhatsApp Business / unverified apps);
- conversation **approved** and identified with **high** confidence (shortcut/locus id);
- not a group chat;
- **no sensitivity flags** — OTP/verification codes, passwords/credentials,
  money/payments/UPI/bank/₹/$/loan/invoice, legal (contract, court, lawyer,
  sign…), medical (doctor, diagnosis, prescription, symptoms, hospital…),
  crisis/emergency/threat/self-harm, high-stakes commitments, unknown sender,
  ambiguous very short text, low identity confidence;
- reply category in your permitted list (default: acknowledgements only);
- drafter confidence ≥ threshold (default 0.85) and drafter did not ask for a human;
- under the per-conversation cap (min of contact cap and global cap, default
  contact cap 0 = never) and the daily cap (default 10);
- outside quiet hours (default 22:00–07:00);
- length ≤ max (default 160 chars);
- the notification has a reply action.

Content flagged as OTP / credentials / crisis is **never sent to AI**.

## AI drafting

`ReplyDrafter` (`application/reply_drafter.dart`) is an interface. The default
`UnconfiguredReplyDrafter` returns "AI drafting unavailable — AI backend not
configured"; nothing is ever faked. The lead overrides `replyDrafterProvider`
(and optionally `conversationSummarizerProvider`) with the coach backend.

A `DraftRequest` contains only: the captured notification text(s) of that one
conversation within retention, your tone profile and the contact's tone
override. Content goes to AI only when **both** `assistant.ai_consent`
(default off, with disclosure) and the app's `allowAi` are on. You can always
write drafts yourself.

### User edits always win

A draft whose text the user typed or edited is never replaced
automatically. A user edit clears the draft's `confidence`; every AI write
sets it, so "non-empty text with no confidence" means user-authored
(`ReplyDraftAuthorship.isUserAuthored`, no schema change). When a new
message arrives in that conversation the draft is re-pointed to the latest
notification but the drafter is **not called** (audit
`ai_draft_skipped;user_edited`). AI writes are compare-and-set in SQL:
they apply only to empty text, the AI's own earlier output, or — for an
explicit **Draft with AI** tap — exactly the text the user saw when tapping.
An edit saved while the drafter is running therefore wins (audit
`ai_draft_discarded;user_edited_or_closed`), and the discarded result is
reported as unavailable so restricted auto-reply can never send the user's
unsent text.

## Delivery semantics

`sendReply` fills the notification's RemoteInput (`RemoteInput.addResultsToIntent`)
and fires its `PendingIntent`. The source app does **not** confirm delivery, so
the best status is **`handed_off`** ("Handed to WhatsApp's reply action; the app
does not confirm delivery") — never "sent" or "delivered".

Failure codes: `notification_gone` (dismissed/replaced — the current active
notification is looked up by key at send time), `no_reply_action`,
`listener_not_connected` (retried **once**), `pending_intent_cancelled`,
`duplicate`, `send_error`. Draft statuses: `draft → pending_approval →
approved → sending → handed_off | failed | unsupported`, plus `rejected` and
`expired`. Transitions are compare-and-set in SQL, so a draft can only enter
`sending` once.

## Dedupe & idempotency

- Dedupe hash: FNV-1a 64 of `package|conversationKey|text|seconds`, where
  seconds is the latest message's MessagingStyle timestamp (falls back to the
  notification post time) — identical in Kotlin and Dart. `CapturedNotifications.dedupeHash`
  is unique and inserts are insert-or-ignore, so re-posted/updated
  notifications and queue+live double delivery create one row and one draft.
- One open draft per conversation; new messages re-point it to the latest
  notification.
- Idempotency key: `r-` + FNV(dedupeHash:draftId), unique in `ReplyDrafts`;
  the native side also keeps an in-memory set of used keys. A draft is never
  sent twice and never retried after `handed_off`.

## Retention, deletion, kill switch

- Captured text expires after the app's retention (default 7 days, 1–90);
  purge runs at start-up. Drafts older than retention have their text blanked
  (open ones become `expired`).
- "Delete all captured messages" deletes every captured row, blanks all draft
  text and clears the native queue.
- Kill switch (Assistant screen, Settings, Capabilities): native listener
  ignores everything and clears its queue, ingestion stores nothing, no
  drafting, all sends refused, Assistant mode stopped. Audited. The kill
  switch keeps your Assistant mode preference, so turning it off restarts
  the service if Assistant mode was on.
- **Stop** on the Assistant mode notification turns Assistant mode off for
  good: the service records the tap natively (`USER_STOP`), and Flutter
  persists `assistant.service_enabled = false` on the next start-up / resume
  (or when the kill switch is turned off) before deciding whether to restart
  it (`AssistantController.restoreService`, audited as
  `source=notification_stop`). Turning Assistant mode on again in the app
  clears the native flag.
- The automation log (`AutomationAudit`) is metadata only (actions, reasons,
  flags, codes; conversation keys hashed). All Dart logging goes through
  `safeLog`, which drops unknown keys and redacts non-identifier strings; the
  Kotlin side logs only exception class names.

## Always-on phone setup (OPPO / ColorOS)

1. Install the debug APK. Because it is sideloaded, Android 13 marks
   notification access as a *restricted setting*: open **App info › ⋮ › Allow
   restricted settings** first if the toggle is greyed out.
2. Assistant › Status › **Set up** notification access (explanation first),
   enable "Athlete OS assistant".
3. Assistant settings: enable WhatsApp (and others) — they start disabled.
4. Battery (Permissions & capabilities › Battery optimization): request the
   exemption, then **Settings › Battery › App battery management › Athlete OS
   › Allow background activity + Allow auto launch**, and lock the app in
   Recents.
5. Optional: turn on **Assistant mode** (foreground service, low-priority
   persistent notification "Athlete OS assistant is running · tap to open ·
   Stop").

Reliability limits: the listener runs in the app process and captures into the
native queue whenever the process is alive. Dart processing (drafting,
approval notifications, briefings) runs while the Flutter engine is alive —
keep the app in Recents (don't back out / swipe it away). ColorOS may still
kill the process without the battery steps above; captured events are then
processed on next launch (queue capped at 500). Morning briefing / evening
review are posted only if the app is alive at that time (checked every
minute, within 3 hours of the configured time, once per day). They are
private on the lock screen ("JARVIS · Briefing ready"); see
docs/PRIVACY.md → Lock screen.

## Limitations

- Notification previews are not full history: long messages may be truncated
  by the source app, media shows as placeholders, and messages you read on
  another device may never notify.
- Edits and deletions in the source app are not reflected; a deleted message
  stays captured until retention.
- Bundled notifications: apps may combine several chats; we read the
  MessagingStyle of each individual conversation notification and skip group
  summaries.
- Group chats are ignored unless approved and are never auto-replied.
- "Possibly unanswered" in the briefing is a heuristic based only on the
  notifications this phone saw.
- No scraping, no private APIs, no accessibility service: Android's
  accessibility policy requires a genuine accessibility use case, which
  messaging automation is not.

## Share sheet

`ACTION_SEND text/plain` opens the app with the text (MethodChannel
`athlete_os/share` `getInitialShare` + EventChannel `athlete_os/share/events`).
The Assistant screen offers *Draft a reply*, *Log food from text*
(`/nutrition/add?q=…`, text also copied) and *Ask coach* (`/coach?prompt=…`).
