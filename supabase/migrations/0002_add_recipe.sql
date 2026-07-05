-- Recipe payload extracted from cooking videos:
-- { "ingredients": ["..."], "steps": ["..."] }
alter table public.saves add column recipe jsonb;
