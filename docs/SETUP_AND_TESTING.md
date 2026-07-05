# Setup & Testing Guide

Everything you need to do to get SocialSaver running and test it end-to-end.
Work top to bottom — later steps depend on earlier ones.

> **Important context:** none of the Swift has been compiled (it was written
> and reviewed without an Xcode/macOS environment). Expect to fix a few
> small mechanical issues on the first build — that's the point of this
> first run. The backend SQL and edge functions can be validated
> independently before you touch Xcode, so do the Supabase half first.

---

## 0. What you need

| Tool / account | For | Notes |
|---|---|---|
| Supabase account + project | Backend (Postgres, Auth, Edge Functions) | Free tier is fine |
| [Supabase CLI](https://supabase.com/docs/guides/cli) | Applying migrations & deploying functions | `brew install supabase/tap/supabase` |
| Anthropic API key | The AI pipeline (classify, extract, plan, chat) | console.anthropic.com → API keys |
| macOS + Xcode 15+ | Building the iOS app | iOS 17 SDK |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Generating the Xcode project | `brew install xcodegen` |
| Apple ID | Signing | A free personal team works for on-device testing |
| One iPhone (or simulator) | Running | Share-extension testing is best on a real device |

For the friends/feed features you'll want **two accounts**, and ideally
**two devices** (or one device + one simulator) to see sharing in both
directions.

---

## 1. Supabase project

1. Create a project at [supabase.com](https://supabase.com). Note the
   **Project URL** and **anon key** (Settings → API).
2. From the repo root, link the CLI to it:
   ```sh
   supabase link --project-ref YOUR_PROJECT_REF
   ```

## 2. Apply the database schema

Push every migration (0001–0013):
```sh
supabase db push
```
This creates all tables, the AI pipeline schema, trips/scheduling, reviews,
discovery, and the friends/feed system with its row-level-security policies.

If `db push` reports it's already partially applied, or you want a clean
slate, reset first (**destroys all data**):
```sh
supabase db reset   # local
# or drop the tables in the dashboard for a hosted project, then db push
```

**Verify the migrations landed** — in the dashboard SQL editor:
```sql
select tablename from pg_tables where schemaname = 'public' order by 1;
-- expect: feed_events, friendships, list_items, lists, place_reviews,
-- places, profiles, save_links, save_notes, save_places, saves,
-- trip_items, trips
```

## 3. Deploy the edge functions

All five, plus the API key secret they share:
```sh
supabase functions deploy process-save
supabase functions deploy ask-saves
supabase functions deploy plan-trip
supabase functions deploy trip-agent
supabase functions deploy discover-videos
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```
`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected automatically; you only
set the Anthropic key.

## 4. Enable email auth

Dashboard → Authentication → Providers → **Email**: enable it. For quick
testing, turn **"Confirm email" off** so sign-up logs you in immediately
(turn it back on before any real launch).

---

## 5. Verify security before wiring up the app (do this once)

The friends/feed migration (0012) rewrote row-level security so friends can
see *shared* content but nothing else. Confirm that with three test users
before trusting it. In the SQL editor:

```sql
-- Create three throwaway auth users first (Authentication → Add user):
--   owner@test.com, friend@test.com, stranger@test.com
-- Grab their UUIDs from the auth.users table, then simulate each one:

-- As OWNER: insert a save, recommend it, and note the save_id.
-- Then check visibility by setting the role claim:
select set_config('request.jwt.claims',
  json_build_object('sub', 'FRIEND_UUID', 'role', 'authenticated')::text, true);
set role authenticated;
select count(*) from saves where id = 'RECOMMENDED_SAVE_ID'; -- expect 1 (friend, once accepted)

select set_config('request.jwt.claims',
  json_build_object('sub', 'STRANGER_UUID', 'role', 'authenticated')::text, true);
select count(*) from saves where id = 'RECOMMENDED_SAVE_ID'; -- expect 0
reset role;
```

The invariants that must hold:

| Scenario | Expected |
|---|---|
| Owner reads own save | visible |
| Accepted friend reads a **recommended** save | visible |
| Accepted friend reads a **non-recommended** save | hidden |
| Stranger reads a recommended save | hidden |
| Anyone reads another user's `save_notes` | hidden (own only) |
| Friend reads a save after owner toggles **Pause sharing** | hidden |
| Friend reads a **friends-visible list**'s items | visible |
| Friend reads a **private** list | hidden |

If any row is wrong, stop and fix the policy before continuing — this is the
one area where a bug means a privacy leak, not just a broken screen.

---

## 6. iOS configuration

1. Create your local config from the template:
   ```sh
   cp Shared/Config/SupabaseConfig.example.swift Shared/Config/SupabaseConfig.swift
   ```
   Fill in `url` and `anonKey` from step 1. This file is gitignored.

2. **Bundle IDs & app group.** The defaults assume the prefix
   `com.ehubbartt`. If that's not you, edit `project.yml`:
   - `PRODUCT_BUNDLE_IDENTIFIER` for both targets (app +
     `.ShareExtension` child)
   - the app group `group.com.ehubbartt.socialsaver` (both targets)
   - the keychain group
   and match `appGroup` / `keychainAccessGroup` in `SupabaseConfig.swift`.
   Whatever prefix you use must be one your Apple team can register.

3. Generate and open the project:
   ```sh
   xcodegen generate
   open SocialSaver.xcodeproj
   ```

4. **Signing.** Select your team on **both** targets (SocialSaver and
   ShareExtension) under Signing & Capabilities. Confirm the App Group and
   Keychain Sharing capabilities resolved (they're declared in the
   entitlements files but need your team to provision).

5. Build (⌘B). **This is where first-build fixes surface** — likely
   candidates if anything: a type name the compiler wants adjusted, or an
   `async` call site. Fix inline; the logic has been reviewed, so these
   should be mechanical.

---

## 7. First-run smoke test (one account)

1. Run on device/simulator, create an account, sign in.
2. **Save a video.** In TikTok or Instagram (or Safari), Share → SocialSaver.
   The extension shows "Saving…". Back in the app, the save appears on the
   Saves grid as "Processing", then fills in with a title, category, places,
   and links once the pipeline finishes (pull to refresh if needed).
   - *If it stays "Processing" or goes to failed:* check the `process-save`
     function logs in the dashboard — almost always the `ANTHROPIC_API_KEY`
     secret or an unreachable link.
3. **Map** tab: saved places appear as pins. Tap one → "Reviews & videos".
4. **Edit:** open a save → ⋯ → Edit. Change the category, fix a place via
   Apple Maps search, add a note. Confirm it persists.
5. **Reviews:** on a place, write a review (stars + worth-it) and confirm
   the summary line updates.
6. **Trip:** Trips tab → create a trip with dates → Add saves, or
   "Auto-plan from my saves". Open the trip agent (bubble icon) and try
   "move the ramen place to day 2". Set a time on a stop and open the day
   Route to see distances and a leave-by time.
7. **Today & briefings:** Profile → Daily briefings → enable, grant the
   notification permission. If a trip is active today, the Trips tab shows
   the "Today" card with weather.

## 8. Friends & feed test (two accounts)

1. On account A: Profile → claim a username (e.g. `alice`).
2. On account B: claim `bob`, then Friends tab (person-plus) → search
   `alice` → Add.
3. On account A: Friends tab → accept bob's request. (This is the flow the
   0013 migration fixes — confirm the request shows **@bob**, not
   "@someone".)
4. On account A: open a save → ⋯ → **Recommend to friends**. Make a list
   friends-visible (person icon in the list). Write a place review.
5. On account B: Friends tab feed → you should see alice's recommended save,
   shared list, and review — and tapping through shows the real content, but
   **not** alice's private note on that save.
6. On account A: Profile → **Your activity & sharing**. Confirm everything
   you shared is listed. Toggle **Pause sharing** → on account B, refresh
   the feed → alice's items disappear. Un-pause → they return.
7. On account A: retract one item (swipe) or unfriend bob → confirm it's
   gone from B's feed.

**The privacy check that matters most:** at no point should account B see
any of account A's saves, lists, or notes that A did *not* explicitly
recommend, share, or review. If B's feed or any screen shows something A
didn't publish, that's a bug — capture which item and stop.

---

## 9. Known limitations (by design, not bugs)

- **Full video watching:** the pipeline reads the caption + cover frame, not
  the full video's frames or audio. A place only spoken aloud won't be
  extracted. (See README for the worker-based upgrade path.)
- **Community discovery** ("more videos about this place") only has content
  once multiple users have saved the same spot; the web-search source is the
  cold-start fallback.
- **Briefing weather** is computed when notifications are scheduled, so it
  can be a few days stale if you don't open the app; opening the Trips tab
  re-schedules with fresh weather.
- **Friends-only sharing is a social boundary, not a cryptographic one** — a
  friend can screenshot anything you share with them.
- **Costs:** every save, auto-plan, agent turn, and web discovery spends
  Anthropic API budget (and web-search usage). Fine for testing; watch the
  meter if you open it up.

## 10. Not yet built (from the architecture doc)

Per-member trip/list sharing with viewer/editor roles, realtime co-editing,
and push notifications for friend requests/invites are designed in
`docs/friends-and-sharing-architecture.md` but not implemented. The current
feed is the read-only "what friends shared" layer; collaborative editing is
the next phase.
