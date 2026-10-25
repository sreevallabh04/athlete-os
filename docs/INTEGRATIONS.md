# Integrations

Each integration sits behind an interface, reports an honest status on the **Integrations**
screen (`Connected`, `Disconnected`, `Needs setup`, `Awaiting credentials`, `Error`) and never
reports `Connected` until a real call has succeeded. If one is unavailable, the rest of the app
keeps working. Detailed setup lives in `docs/integrations/`.

## Status summary (as of 2026-10-25)

| Integration | Mechanism | Works without setup? | What you must provide | Third-party cost | Details |
|---|---|---|---|---|---|
| Health Connect (Android) | `health` plugin 13.3.2, on-device | Needs Health Connect app (Android 13) + permissions | Install Health Connect from Play Store; grant read permissions | Free | [health-connect.md](integrations/health-connect.md) |
| Samsung Health / Galaxy Watch | **Via Health Connect** | — | Samsung Health ≥ 6.22.5 on the same phone with Health Connect sync on; watch paired to that phone | Free | [health-connect.md](integrations/health-connect.md) |
| Hevy | Official API v1 (`api-key` header) | No | **Hevy Pro** + API key from hevy.com/settings?developer | Hevy Pro subscription | [hevy.md](integrations/hevy.md) |
| Strava | Official OAuth + API v3; token exchange in Supabase Edge Function | No | Strava API app (callback domain `localhost`), Supabase project, function deployed with secrets | Free (API); Supabase free tier | [strava.md](integrations/strava.md) |
| Google Calendar | `google_sign_in` 7 + Calendar API v3 | No | Google Cloud project, Calendar API enabled, OAuth consent (Testing), Android + Web client IDs | Free | [google-calendar.md](integrations/google-calendar.md) |
| Open Food Facts | Public API v3 / search | **Yes** | Optional contact email for the User-Agent | Free (ODbL attribution) | [food-data.md](integrations/food-data.md) |
| USDA FoodData Central | Public API | No | Free data.gov API key | Free | [food-data.md](integrations/food-data.md) |
| AI providers — **live**: Gemini (primary, `gemini-3.6-flash`) → Groq (fallback, `openai/gpt-oss-120b`); Anthropic / OpenAI supported but not configured | Supabase Edge Functions `ai-chat` / `ai-status` on project `gbvtlzkcqjligajsnoll` (Mumbai) | No (anonymous sign-in is automatic) | Done: keys are server secrets, one secondary Gemini key for failover only | Free tiers today; **pay per token** on paid tiers (global cap $10/month) | [AI_AGENT.md](AI_AGENT.md), [BACKEND_DEPLOY.md](BACKEND_DEPLOY.md) |
| Messaging assistant (WhatsApp, SMS, …) | Android NotificationListenerService + notification reply actions | Needs notification access | Grant notification access; per-app enable | AI drafting uses the AI provider (paid) | [MESSAGING_ASSISTANT.md](MESSAGING_ASSISTANT.md) |

## Policy constraints that shape the design

- **Strava API Policy (effective 2026-06-01) §5.3** forbids using Strava data — including
  derived data — with any AI application, including putting it into an LLM context window.
  Strava activities are therefore shown to you with an on-device, rule-based analysis only, and
  are excluded from every AI tool (enforced and tested in code). The AI coach analyses runs that
  arrive via Health Connect instead. Strava data is refreshed or purged within 7 days (§6.2)
  and deleted on disconnect.
- **WhatsApp Terms of Service** prohibit auto-messaging on personal accounts, and the WhatsApp
  Business Platform cannot attach to a personal account. WhatsApp replies are therefore
  draft/approval only and sent through WhatsApp's own notification reply action when you tap
  Send. Restricted auto-reply is blocked for WhatsApp in code.
- **Samsung Health** has no unrestricted third-party API (its Data SDK requires partner
  approval), so the app reads Samsung Health data through Health Connect.
- **Google OAuth in Testing mode** expires consent after 7 days; you'll be asked to reconnect
  weekly unless the OAuth app is verified.
- **Open Food Facts** asks for ≤ 15 product reads and ≤ 10 searches per minute and a
  descriptive User-Agent; the client enforces both.

## Credentials: where each one lives

| Credential | Where | Never |
|---|---|---|
| Supabase URL, anon/publishable key, Strava client ID, Google Web client ID | `config/dev.json` (git-ignored) → `--dart-define-from-file` | — (public identifiers) |
| AI provider keys, Strava client secret, Supabase service-role key | Supabase secrets (`supabase secrets set`) / local `supabase/functions/.env` | In the app, in Git, in logs |
| Hevy API key, Strava access token | `flutter_secure_storage` on the device (Android Keystore-backed) | In logs or exports |
| Strava refresh token | Server table `strava_tokens` (service role only) | On the device |

## First-time setup order (recommended)

1. **Local-only features work immediately:** food (Open Food Facts), water, habits, mood, journal,
   competition, planner, reports, manual workouts.
2. **Health Connect** on the phone (install, grant permissions, connect Samsung Health if used).
3. **Hevy** (paste key in Integrations › Hevy).
4. **Supabase** project → `supabase db push` → set secrets → deploy functions → put URL + anon key
   in `config/dev.json` → rebuild. This unlocks the AI coach, AI drafting and Strava.
5. **Strava** app registration → secrets → connect in the app.
6. **Google Calendar** OAuth clients → `GOOGLE_WEB_CLIENT_ID` in `config/dev.json` → rebuild →
   connect.
