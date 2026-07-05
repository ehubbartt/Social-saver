# Friends & Sharing — Architecture Review

Design review for adding friends, shared trips, and shared lists. Written
before implementation because this feature rewrites the app's security model:
today every table is single-owner (`user_id = auth.uid()` everywhere), and
sharing breaks that assumption in cascading ways.

## What sharing collides with today

| Existing assumption | Where it lives | Breaks because |
|---|---|---|
| Every row has one owner | RLS on all 8 tables | Members need read (and sometimes write) access |
| A save is visible only to its owner | `saves`, `save_places`, `save_links` RLS | A shared trip's items JOIN saves owned by someone else — embeds silently return null for members |
| "My saves" = whatever RLS returns | `SavesRepository.fetchSaves`, map pins, `ask-saves` | Once saves become visible via shares, unfiltered queries would pollute the home grid with friends' saves |
| Profiles are private | `profiles` RLS (own row only) | Friends need discovery — but opening profiles invites enumeration |
| Edge functions rely on RLS alone | `plan-trip`, `trip-agent` | RLS distinguishes owner/non-owner, not editor/viewer |

## Decisions

### D1. Friendship: single canonical row with request flow

```
friendships (
  id, requester → profiles, addressee → profiles,
  status: pending | accepted,
  created_at, responded_at,
  check (requester <> addressee),
  unique index on (least(requester, addressee), greatest(requester, addressee))
)
```

One row per pair (canonical ordering prevents A→B and B→A duplicates), with
`requester` preserving who asked. **Rejected:** two mirrored rows (the common
alternative) — doubles every write and invites divergence bugs. `blocked`
status is a straightforward later addition to the same enum.

### D2. Discovery: usernames + exact-match lookup RPC

`profiles.username` exists but is nullable and unreachable (RLS: own row
only). Plan:

- Unique **case-insensitive** index on `lower(username)`; a claim-username
  step in Profile before friend features unlock.
- Lookup via a `security definer` SQL function `lookup_username(text)`
  returning only `(id, username)` on **exact match**. This is the whole
  discovery surface: no broad select policy on profiles, no substring search,
  so no scraping the user table. **Rejected:** opening `profiles` select to
  all authenticated users — RLS has no column-level control, and it enables
  enumeration.

### D3. Membership: per-resource member tables, two roles

```
trip_members (trip_id, user_id, role: viewer|editor, invited_by, created_at, pk (trip_id, user_id))
list_members (list_id, user_id, role: viewer|editor, invited_by, created_at, pk (list_id, user_id))
```

**Rejected:** a generic polymorphic `shares(resource_type, resource_id,
user_id)` table — no FK integrity, no cascade on container delete, and every
RLS policy grows a type discriminator. Two small tables with real FKs are
simpler in every dimension that matters. Only accepted friends of the owner
can be invited (app-level check + a `security definer` trigger for
integrity). The owner is implicit (not a member row): owner rights come from
`trips.user_id`, which avoids "who deletes the owner's member row" edge
cases.

### D4. RLS: security-definer helper functions, not inline subqueries

The classic Supabase failure mode: `trip_members` policies that reference
`trip_members` (or `trips` policies referencing a table whose policies
reference `trips`) recurse and error at query time. The fix is a small set of
`security definer stable` helpers whose internal queries bypass RLS:

```sql
can_access_trip(trip_id)  -- owner OR any member
can_edit_trip(trip_id)    -- owner OR member with role 'editor'
can_access_list(list_id) / can_edit_list(list_id)
save_is_shared_with_me(save_id)  -- see D5
```

Policy matrix after the rewrite:

| Table | select | insert | update | delete |
|---|---|---|---|---|
| trips | owner or member | own rows | owner | owner |
| trip_members | can_access_trip | owner (invite) | owner (role change) | owner, or self (leave) |
| trip_items | can_access_trip | can_edit_trip | can_edit_trip | can_edit_trip |
| lists / list_members / list_items | same pattern | | | |
| saves | owner **or shared** (D5) | owner | owner | owner |
| save_places, save_links | follows saves visibility via helper | owner-side unchanged | | |

Note `saves` write policies stay owner-only: members see a shared save, they
never edit someone else's save. Editors add *their own* saves to a shared
trip — which is exactly why visibility must be computed from containers, not
ownership (D5), in both directions.

### D5. The crux: how members see saves they don't own

A shared trip's items point at `saves` rows owned by the sharer. Three
options considered:

| Option | Live data | Privacy | Complexity | Verdict |
|---|---|---|---|---|
| **A. Reference + visibility policy** — `saves` select gains `or save_is_shared_with_me(id)`: the helper checks whether the save appears in any trip/list the viewer can access | ✅ places, links, recipes all flow through existing joins | exposes the save's fields to members | one helper + policy churn | **Chosen** |
| B. Snapshot copy — freeze title/thumbnail into `trip_items` at add time | ❌ stale; breaks place joins → shared trip maps and routes die | ✅ | duplicate schema | Rejected |
| C. Clone the save into the member's account | ❌ forks data | ✅ | heavy, confusing | Rejected |

Option A keeps the map, day routes, links, and recipes working for members
with zero denormalization. Cost: the policy runs per row — mitigated because
the helper is `stable` (evaluated once per row via index-backed EXISTS), and
`trip_items.save_id` / `list_items.save_id` are already indexed; add member
`user_id` indexes.

**Privacy carve-out — personal notes.** `saves.note` is explicitly "My note"
in the UI; leaking it to trip members is a real surprise. Recommendation:
move notes to a `save_notes (save_id, user_id, note, pk(save_id, user_id))`
table in the same migration — private per user by RLS, and it upgrades the
feature for free (each member can keep their own note on a shared save).
The `note` column was added recently and is written from one screen, so the
client change is one repository method + the same edit-sheet field.

### D6. Edge functions

All functions run under the caller's JWT, so read scoping follows RLS
automatically — a member's `trip-agent` call sees the shared trip with no
code change. Required adjustments:

- **plan-trip / trip-agent:** check `can_edit_trip` up front and return a
  clear 403 for viewers (today a viewer would get confusing per-write RLS
  errors mid-run). Keep the saves catalog scoped to the **caller's own**
  saves (`eq user_id`) — the agent plans from *your* videos even on a shared
  trip; mixing in other members' full catalogs is a scope decision to make
  deliberately later, not a default.
- **ask-saves:** add explicit `eq("user_id", caller)` — after D5, the
  unfiltered query would leak friends' shared saves into "your" catalog.

### D7. Client changes (bounded list)

- `SavesRepository.fetchSaves` and the map pins: add explicit
  `eq("user_id", me)` — home grid stays "my saves". Shared saves surface
  only inside shared containers.
- New `FriendsRepository` (request/accept/decline/remove, lookup) +
  member methods on trips/lists repositories.
- Profile: claim-username step, Friends screen (requests inbox + list).
- Trip and list detail: Members sheet — invite from friends, set
  viewer/editor, remove; "Leave" for members; a "shared" badge and owner
  attribution on rows arriving via shares.
- Fetching trips/lists now returns shared ones automatically (RLS) — the UI
  needs owner labels, not new queries.

### D8. Explicitly deferred (phase 3+)

- **Realtime co-editing** — Supabase Realtime channel per trip for live
  itinerary updates; v1 ships pull-to-refresh, which the UI already does.
- **Push notifications** for requests/invites (needs APNs setup).
- Albo-style extras the member tables make cheap later: wanna-voting
  (`votes(item_id, user_id)`), in-trip chat between members, blend lists.
- Friend removal revoking memberships — v1 keeps existing memberships on
  unfriend (removal is explicit per container); revisit if it feels wrong.

## Migration plan

Two migrations (numbers assigned at implementation time — discovery and
reviews have since claimed 0009/0010, and both independently validated the
patterns this plan relies on: `videos_for_place` uses the security-definer
approach, and `place_reviews` establishes community-readable content
alongside private saves):

- `..._friends.sql` — username uniqueness + `lookup_username` RPC +
  `friendships` + its RLS.
- `..._sharing.sql` — member tables, helper functions, full policy rewrite
  (drop + recreate as new migration files, never editing applied ones),
  `save_notes` migration (`insert ... select from saves where note is not
  null`, then drop `saves.note`), and the new indexes.

Phases: **1** friends (usernames, requests, UI) → **2** sharing (members,
RLS rewrite, member UI, function/client filters) → **3** realtime + social
polish. 1 and 2 are separately shippable; 2 is where all the risk lives, so
its migration should land with SQL smoke tests (owner/member/stranger
access matrix run as three test users) before the client work starts.

## Top risks

1. **RLS recursion or perf regressions** from the policy rewrite — mitigated
   by the definer-helper pattern, new indexes, and testing the access matrix
   in SQL before touching Swift.
2. **Save-visibility scope creep** — D5 exposes summary/links/recipe of a
   shared save by design; notes are carved out. Anything else personal added
   to `saves` later must consider shared visibility.
3. **Client assumptions** — any query that implicitly meant "mine" must gain
   an explicit filter (audited: `fetchSaves`, map pins, `ask-saves`,
   agent catalogs).
