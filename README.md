# SocialSaver

Save videos from TikTok and Instagram straight from the share sheet. Each save
is automatically classified (restaurant, recipe, activity, …), summarized, its
places are extracted and pinned on a map, and it's filed into the right list —
inspired by apps like Albo.

Native iOS (SwiftUI, iOS 17+) with a Supabase backend (Postgres + Auth + Edge
Functions). The smart-save pipeline uses the Claude API for classification and
place extraction.

## How it works

```
TikTok / Instagram share sheet
        │  (URL)
        ▼
Share Extension ──► Edge Function: process-save
                        │ 1. create pending save (RLS-scoped)
                        │ 2. resolve link metadata (oEmbed / OpenGraph)
                        │ 3. download the video's cover frame
                        │ 4. Claude (vision + caption + web search): classify,
                        │    summarize, read on-screen text overlays, extract
                        │    places and recipes, look up real links (websites,
                        │    phone numbers, App Store pages, booking pages),
                        │    pick or create the best list
                        │ 5. geocode places (Nominatim) → map pins
                        ▼
                    Postgres (saves, places, lists)
                        ▲
        App tabs: Saves grid │ Map │ Lists │ Profile
```

## Feature parity with Albo — and its weak points fixed

| | Albo | SocialSaver |
|---|---|---|
| Share-sheet saving (TikTok/IG/any URL) | ✅ | ✅ |
| Auto-categorization | ✅ (no way to fix mistakes) | ✅ **+ fully editable** |
| Place extraction → map | ✅ (one place per video) | ✅ **multiple places per video** |
| Recipe extraction | ✅ | ✅ |
| Smart list filing | ✅ | ✅ (+ manual add/remove/move) |
| Links & contact info for mentions | ❌ | ✅ website/phone/App Store/booking |
| "Chat to Albo" ask assistant | ✅ | ✅ Ask tab (grounded in your saves) |
| Notes on items | ✅ | ✅ personal note per save |
| Import / how-to-save guides | ✅ | ✅ in-app guide (Profile tab) |
| Search within saves | ❌ (top complaint) | ✅ home grid **and inside lists** |
| Bulk organize | ❌ (requested, missing) | ✅ multi-select → add to list / delete |
| Fix a wrong location | ❌ | ✅ replace via Apple Maps search |
| Share a list | ✅ (requires accounts) | ✅ text export via share sheet |
| Trip planning | ➖ (map only) | ✅ **trips with day-by-day itineraries + AI auto-plan** |
| Social layer (friends, blends) | ✅ | ➖ future (schema supports it) |

AI extraction can be wrong, so **everything it writes is editable**: open a
save → ⋯ → Edit to change the title, summary, and category, and to remove,
replace, or add places. Place corrections go through Apple Maps search, so
the fixed pin has real coordinates and a real address.

### Trip planner

The Trips tab turns saves into actual travel plans. Create a trip (name,
destination, vacation dates) and build each day's schedule:

- **Drag & drop** — press and hold any stop and drag it onto a day (or back
  to Ideas); ordering within a day is preserved. A menu offers the same moves
  for one-handed use.
- **Auto-plan from my saves** — the backend picks the saves that belong on
  this trip and groups them into sensible days (same neighborhood together,
  2–5 items per day), each with a short placement note. Re-run anytime;
  manual choices are never deleted.
- **Flights, hotels & custom stops** — add non-save entries with a title,
  details (confirmation #), a day, a time, and an optional location via
  Apple Maps search.
- **Day route ("wire map")** — each day header has a Route button showing
  numbered stops connected by real walking/driving routes, with distance and
  travel time per leg (dashed straight line as a fallback estimate when
  directions are unavailable).
- **When to leave** — give a stop a time (e.g. a 13:00 reservation or a
  flight departure) and the route view computes "Leave by 12:38 to arrive
  13:00" from the actual travel time of that leg.
- **Trip assistant** — a chat agent per trip (bubble icon) that answers
  questions, recommends what to do (with live web search), and edits the
  itinerary on request: "move the ramen spot to day 3", "add my flight,
  UA 837 landing 14:20 day 1", "find a breakfast place near the hotel and
  add it". The agent can only touch the trip through six strictly-typed
  tools (add stop, add save, move, set time, set note, remove) whose inputs
  are schema-enforced and re-validated server-side under the user's own
  session — days must be 1..N or Ideas, times must be HH:MM, ids must be
  real, removals only on explicit request, and it can never see or modify
  anything outside the current trip.

## Setup

### 1. Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Link and push the schema:
   ```sh
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   ```
3. Deploy the edge functions and set your Claude API key:
   ```sh
   supabase functions deploy process-save
   supabase functions deploy ask-saves
   supabase functions deploy plan-trip
   supabase functions deploy trip-agent
   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
   ```
4. In Authentication settings, enable Email sign-in (email confirmation
   optional — turn it off for quick local testing).

### 2. iOS app

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Create your config file:
   ```sh
   cp Shared/Config/SupabaseConfig.example.swift Shared/Config/SupabaseConfig.swift
   ```
   Fill in your project URL and anon key (Supabase dashboard → Settings → API).
3. Generate and open the project:
   ```sh
   xcodegen generate
   open SocialSaver.xcodeproj
   ```
4. In Signing & Capabilities, select your team for **both** targets
   (SocialSaver and ShareExtension). If your bundle prefix isn't
   `com.ehubbartt`, update the bundle IDs, the app group
   (`group.com.ehubbartt.socialsaver`), and the keychain access group in
   `project.yml` + `SupabaseConfig.swift`, then re-run `xcodegen generate`.
5. Run on a device or simulator, create an account, then share a TikTok or
   Instagram link and pick **SocialSaver** in the share sheet.

The app and the share extension share the auth session through a keychain
access group, so signing in once in the app is enough.

## How much of the video does it "see"?

The pipeline sends the video's **cover frame** to the model along with the
caption. That covers most real-world cases: creators usually burn the place
name, dish, or itinerary text into the cover, and the model reads those
overlays plus the visible scene. It does **not** download or play the full
video.

Full video understanding (sampling frames throughout + transcribing the audio)
would need a worker with `yt-dlp` + `ffmpeg` + a transcription model, since
video downloads rely on unofficial endpoints and don't fit in an edge
function's runtime or limits. The extraction schema and prompt are already
written so that adding "frames + transcript" to the same Claude call is the
only change needed if you stand up such a worker later.

## Notes & limitations

- Link finding uses the Claude API's server-side web search tool, so URLs and
  phone numbers come from actual search results, never model guesses. Web
  search is billed per use on your API key (a few searches per save at most).
- Extraction quality depends on what's publicly visible: caption, hashtags,
  and the cover frame. A video whose place is only spoken aloud won't be
  extractable until audio transcription is added (see above).
- Instagram doesn't offer a public oEmbed endpoint, so metadata comes from
  OpenGraph tags; some links resolve to a login wall and yield thin metadata.
  The pipeline still classifies from the URL and whatever it can read.
- Geocoding uses OpenStreetMap Nominatim (free, rate-limited to ~1 req/s).
  Swap in Google Places in `supabase/functions/process-save/index.ts` if you
  need higher accuracy for business names.
- Places are deduplicated globally by (name, city, country), which lays the
  groundwork for Albo-style social layers (trending places, friends' saves).
