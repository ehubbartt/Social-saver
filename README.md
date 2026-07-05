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
                        │ 3. Claude: classify + summarize + extract places
                        │    + pick or create the best list
                        │ 4. geocode places (Nominatim) → map pins
                        ▼
                    Postgres (saves, places, lists)
                        ▲
        App tabs: Saves grid │ Map │ Lists │ Profile
```

## Setup

### 1. Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Link and push the schema:
   ```sh
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   ```
3. Deploy the ingest function and set your Claude API key:
   ```sh
   supabase functions deploy process-save
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

## Notes & limitations

- Instagram doesn't offer a public oEmbed endpoint, so metadata comes from
  OpenGraph tags; some links resolve to a login wall and yield thin metadata.
  The pipeline still classifies from the URL and whatever it can read.
- Geocoding uses OpenStreetMap Nominatim (free, rate-limited to ~1 req/s).
  Swap in Google Places in `supabase/functions/process-save/index.ts` if you
  need higher accuracy for business names.
- Places are deduplicated globally by (name, city, country), which lays the
  groundwork for Albo-style social layers (trending places, friends' saves).
