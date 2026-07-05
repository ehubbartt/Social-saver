# SocialSaver

Native iOS app (Swift 5.9, SwiftUI, iOS 17+) for saving TikTok/Instagram videos
via the share sheet. An AI pipeline classifies each save, extracts places, pins
them on a map, and files the save into lists automatically. Backend is Supabase
(Postgres + Auth + Edge Functions).

## Layout

- `SocialSaver/` — main app target (tabs: Saves, Map, Lists, Profile)
- `ShareExtension/` — share-sheet extension; sends shared URLs to the ingest function
- `Shared/` — code compiled into both targets (models, Supabase client, repositories, config)
- `supabase/migrations/` — schema + RLS policies
- `supabase/functions/process-save/` — ingest pipeline (metadata → classify → geocode → file into list)
- `project.yml` — XcodeGen spec; run `xcodegen generate` to produce the Xcode project

## Conventions

- Commits, PRs, code comments, and branch names must not contain any AI/assistant
  attribution or tooling references. Author all commits as
  `Ethan Hubbartt <ehubbartt@gmail.com>`.
- `Shared/Config/SupabaseConfig.swift` is gitignored; never commit credentials.
  Update `SupabaseConfig.example.swift` when config keys change.
- Database changes go through new files in `supabase/migrations/` — never edit
  an applied migration.
- Swift code targets iOS 17 APIs (Observation framework, SwiftUI MapKit).
- Decodable models declare explicit snake_case `CodingKeys` for Postgres columns.
