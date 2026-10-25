# Google Calendar integration

Athlete OS reads your Google calendars to plan training around your day, and can
optionally add events it creates (workouts, meal prep, focus blocks, habits).
It never edits or deletes events it did not create.

## 1. Google Cloud project

1. Open <https://console.cloud.google.com> and create (or pick) a project.
2. **APIs & Services -> Library**: enable the **Google Calendar API**.

## 2. OAuth consent screen

1. **APIs & Services -> OAuth consent screen**.
2. User type: **External**. Publishing status: **Testing**.
3. Fill in app name and support email.
4. Add the scopes listed below.
5. Under **Test users**, add your own Google account (up to 100 test users).

> **Important: 7-day expiry in Testing mode.** While the consent screen is in
> Testing, Google expires consent and refresh tokens after **7 days**. The app
> then shows **Needs reconnect** on the Google Calendar card; tap it and consent
> again (weekly). To avoid this, publish the app and complete Google's
> verification for the sensitive calendar scopes.

## 3. OAuth clients

You need **two** clients in **APIs & Services -> Credentials**.

### Web client

1. **Create credentials -> OAuth client ID -> Web application**.
2. Copy its client ID into `config/dev.json`:

   ```json
   { "GOOGLE_WEB_CLIENT_ID": "1234567890-xxxx.apps.googleusercontent.com" }
   ```

3. Run with `flutter run --dart-define-from-file=config/dev.json`.

`google_sign_in` 7.x uses this value as `serverClientId`. Without it, Android
sign-in fails with a configuration error.

### Android client

1. **Create credentials -> OAuth client ID -> Android**.
2. Package name: `com.athleteos.athlete_os`.
3. SHA-1 of the debug signing key (Windows):

   ```bat
   keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android
   ```

4. For release builds, add another Android client (or fingerprint) with the
   **release** key SHA-1 as well.

The Android client has no secret and its ID is not referenced in code; Google
matches it by package name + SHA-1.

## Scopes

| Scope | When requested | Why |
| --- | --- | --- |
| `https://www.googleapis.com/auth/calendar.readonly` | When you tap **Connect** | List your calendars and read events across the calendars you select |
| `https://www.googleapis.com/auth/calendar.events` | Incrementally, only the first time you create an event | Insert events the app creates |

Writing is always explicit:

1. You choose to create an event (workout, meal prep, focus block or habit).
2. The app checks for conflicts in the selected calendars and shows them.
3. A confirmation dialog shows the title, time and target calendar.
4. Only after you confirm is the event inserted.

The app never edits or deletes existing events.

## Data handling

- **Calendar selection** (which calendars to read) is persisted locally.
- **Events are not stored.** They are fetched when needed and kept in memory.
- The only stored calendar data are references to events the app itself
  created (`CalendarEventRefs`: event id, calendar id, linked item), so it can
  show "added to calendar" and avoid duplicates.

## Time zones

Events are read with their own time zone (`start.timeZone` / offset) and
displayed in the device's local time. All-day events are treated as dates, not
midnight-to-midnight times. Events the app creates use the device time zone.

## Disconnect

**Integrations -> Google Calendar -> Disconnect** signs out of Google, revokes
the app's access, and clears the calendar selection. `CalendarEventRefs` are
removed; the events themselves stay in your calendar.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `DEVELOPER_ERROR` / `clientConfigurationError` | SHA-1 or package name of the Android client does not match the build, or `GOOGLE_WEB_CLIENT_ID` (serverClientId) is missing. Re-run `keytool`, check the package `com.athleteos.athlete_os`, and check `config/dev.json`. |
| Sign-in `canceled` | You closed the account picker or consent screen; tap Connect again. |
| `403 access_not_configured` | Google Calendar API is not enabled in the Cloud project. |
| `403 access_denied` / "app not verified" blocks you | Your account is not on the consent screen's test users list. |
| Works for a week, then **Needs reconnect** | Expected in Testing mode (7-day token expiry). Reconnect, or publish the app. |
| Release build cannot sign in, debug works | Add the release key SHA-1 to an Android OAuth client. |
| Event times look shifted | Check the device time zone; events are converted to local time. |
| "Insufficient permissions" when creating an event | The `calendar.events` scope was declined; create the event again and accept. |
