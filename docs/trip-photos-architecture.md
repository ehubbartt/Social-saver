# Trip Photos — Architecture Review

Design review for: access the camera roll, smart-suggest photos taken at a
planned place, attach them to your review of that place, and let others on
the trip/list see them. Heavy feature — new device permission, new server
infrastructure (photo storage), and it depends on a sharing layer that isn't
built yet. Written before implementation.

## Feasibility

Yes, all three pieces are standard:
- **Camera roll + smart matching** — PhotoKit. `PHAsset` exposes
  `.location` (GPS) and `.creationDate`. Match = photos whose coordinates
  are within ~150 m of a planned place *and* whose timestamp falls in the
  trip's date range (or that specific day). Date is a `PHFetchOptions`
  predicate; distance is filtered in memory after the date fetch.
- **Storage** — Supabase Storage (new to this project; we've used only
  Postgres so far). A private bucket, downloads via signed URLs minted after
  an auth/visibility check.
- **Sharing** — reuse the security-definer visibility pattern from the feed.

## The dependency problem (the thing to decide)

The ask says "if other people are **part of the trip or the list** they can
see the photos." But that membership concept **does not exist yet**:

- **Trips are single-owner.** There is no "people on a trip." Multi-member
  trips with viewer/editor roles were explicitly *deferred* in
  `friends-and-sharing-architecture.md` (§D3) and never built.
- **Lists** can be *friends-visible* (anyone you've friended sees them via
  the feed), but that's visibility, not membership — there's no "these three
  people are collaborating on this list."

So the sharing half of this feature can't be built as literally described
without first building the membership layer. That's the fork, and it's the
one thing I need your call on (below).

## Privacy principles (non-negotiable, whichever path)

Camera-roll access + uploading photos to a server others can see is the most
sensitive thing the app would do. The rules:

1. **Nothing auto-uploads.** The app *suggests* matched photos; you
   explicitly pick which to attach. Same "no implicit publish" stance as the
   feed. A photo reaches the server only when you choose to attach it.
2. **Only the chosen photo leaves the device**, re-encoded as a fresh JPEG
   with **EXIF/GPS stripped** — we keep the match coordinates we already
   computed, but never upload the original file's metadata (which can carry
   home addresses, camera serials, etc.).
3. **Graceful with Limited Photo access.** iOS lets users grant only
   specific photos. Smart-matching wants library-wide read, so we ask for
   full access with a clear purpose string — but if the user grants Limited,
   we fall back to "attach from your selected photos" instead of failing.
4. **Private bucket, authorized downloads only.** No public URLs. A viewer
   gets a short-lived signed URL only after a server-side visibility check.
5. **Delete means delete.** Removing a photo deletes the storage object, not
   just the row.

## Storage & data model

Private bucket `trip-photos`. Object path `{owner_id}/{photo_uuid}.jpg` so
Storage RLS can gate *writes* by path prefix (you can only write under your
own id). *Reads* go through an edge function that checks visibility and
returns a signed URL — keeping all the visibility logic in one place and the
bucket fully private.

```
photos (
  id            uuid pk,
  owner_id      uuid -> profiles,
  storage_path  text,               -- {owner_id}/{uuid}.jpg
  place_id      uuid -> places,     -- which place it documents
  trip_id       uuid -> trips null, -- the visit context (drives sharing)
  taken_at      timestamptz null,
  latitude      double precision null,
  longitude     double precision null,
  created_at    timestamptz
)
```

Attaching to a **place** (not a specific review row) means the photo shows on
your review of that place *and* in the trip. `trip_id` records the visit and
is what sharing keys off.

## Visibility — the tension to resolve

Reviews today are **community-readable** (any signed-in user sees the stars +
text). Photos are more personal than a star rating, so they should **not**
inherit the review's public visibility. Proposed rule:

> A photo is visible to: its owner; anyone who can see the **trip** it
> belongs to; and (optionally) friends, if the owner also recommended/shared
> the review.

That "can see the trip" clause is exactly the membership gap. Options:

| Path | What it means | Cost | Matches the ask? |
|---|---|---|---|
| **A. Build trip membership first** | Add `trip_members` (viewer/editor) from the deferred design; photos visible to members. Trips become genuinely shared. | High — the deferred D3 feature, RLS on trips/trip_items, invite UI | Fully |
| **B. Scope to the friends model** | No trip members. Photos visible to *friends* when you attach them to a shared/recommended review. Personal trip photo album otherwise. | Low — reuses feed helpers | Partially ("friends" not "trip members") |
| **C. Lightweight trip companions** | A minimal read-only `trip_members` (people you add to a trip see it, no editing) — just enough for photo sharing, roles later | Medium | Mostly |

**My recommendation: A**, done as its own phase *before* photos. Rationale:
"shared trips" is a real product pillar (it's half of what you originally
asked friends for), photos are the feature that makes it worth building, and
B leaves you with an odd "friends see my trip photos but aren't on my trip"
model that you'd rip out later. C is a false economy — it's 80% of A's work
for a version you'll replace. Building A means: `trip_members` +
`list_members` tables, the `can_access_trip`/`can_edit_trip` helpers, RLS on
trips/trip_items, an invite-from-friends UI, and then photos ride on top
cleanly.

If you'd rather see photos working sooner and defer real trip-sharing, **B**
ships in a fraction of the time and photos become "attach to your review,
friends can see them," with true trip membership as a later upgrade.

## Rough plan (for Path A)

1. **Phase 1 — trip/list membership** (the deferred sharing layer):
   `trip_members`/`list_members`, access helpers, RLS rewrite for
   trips/trip_items, invite-from-friends UI, "shared with you" trips in the
   list.
2. **Phase 2 — photos**: Storage bucket + RLS, `photos` table + visibility
   helper + signed-URL edge function, PhotoKit matching service, a
   "Suggested photos from your trip" picker in the review sheet and trip day,
   photo galleries on the place hub and trip.

Phase 1 is independently valuable (shared trips) and unblocks Phase 2.

## Top risks

1. **Privacy perception** — camera-roll + upload is exactly the kind of
   feature that scares users. The "nothing auto-uploads, EXIF stripped,
   private bucket" design must be real and visible in the UI, not just
   backend.
2. **Storage cost/abuse** — photos are big. Cap resolution (e.g. 1600 px
   long edge), one reasonable JPEG per attach, and a per-user quota.
3. **Matching accuracy** — GPS on photos is noisy indoors; 150 m radius +
   the day window is a starting point to tune, and matches must always be
   user-confirmed, never auto-attached.
