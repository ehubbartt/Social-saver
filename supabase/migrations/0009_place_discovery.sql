-- Community discovery: other videos saved for the same place.
--
-- Saves stay private (RLS untouched). This security-definer function is the
-- only cross-user surface, and it returns ONLY public video metadata — the
-- link, title, thumbnail, and platform — never the saver's identity, notes,
-- or lists. Deduplicated by video URL.
create or replace function public.videos_for_place(p_place_id uuid)
returns table (
  title text,
  thumbnail_url text,
  source_url text,
  source_platform text
)
language sql
security definer
stable
set search_path = public
as $$
  select distinct on (s.source_url)
    s.title,
    s.thumbnail_url,
    s.source_url,
    s.source_platform
  from saves s
  join save_places sp on sp.save_id = s.id
  where sp.place_id = p_place_id
    and s.status = 'processed'
    and s.user_id <> auth.uid()
  order by s.source_url, s.created_at desc
  limit 20;
$$;

revoke all on function public.videos_for_place(uuid) from public, anon;
grant execute on function public.videos_for_place(uuid) to authenticated;
