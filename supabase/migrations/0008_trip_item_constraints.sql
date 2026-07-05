-- Database-level backstop for the trip agent and app clients: whatever a
-- caller manages to send, trip items stay structurally coherent.
alter table public.trip_items
  add constraint trip_items_kind_check
    check (kind in ('save', 'flight', 'hotel', 'transport', 'custom')),
  add constraint trip_items_save_presence
    check ((kind = 'save') = (save_id is not null)),
  add constraint trip_items_day_range
    check (day_index is null or (day_index >= 1 and day_index <= 31));
