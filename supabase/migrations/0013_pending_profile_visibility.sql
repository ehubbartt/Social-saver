-- Friend requests embed the other person's profile, but a pending request is
-- between two people who aren't accepted friends yet — so the prior
-- "friends read profiles" (accepted-only) policy returned null and every
-- incoming/outgoing request showed "@someone". Broaden profile reads to
-- anyone sharing a friendship row of any status. Harmless: a pending
-- requester already typed your exact username to reach you.

create or replace function public.has_friendship_edge(p_other uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists (
    select 1 from friendships
    where (requester = auth.uid() and addressee = p_other)
       or (requester = p_other and addressee = auth.uid())
  );
$$;

revoke all on function public.has_friendship_edge(uuid) from public, anon;
grant execute on function public.has_friendship_edge(uuid) to authenticated;

drop policy "friends read profiles" on public.profiles;
create policy "friendship profiles readable" on public.profiles
  for select to authenticated
  using (has_friendship_edge(id));
