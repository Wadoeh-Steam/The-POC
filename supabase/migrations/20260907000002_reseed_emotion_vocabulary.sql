-- Both emotion_label_vocabulary and emotion_association_vocabulary are
-- unexpectedly empty on the live project — including the original 16/4-row
-- seeds from 20260814000001_initial_schema.sql, which the migration
-- tracking table has always shown as applied. Found live 2026-09-07: every
-- real label submission failed validate_emotion_vocabulary() with "Unknown
-- emotion label(s)", not just the newly-expanded set from
-- 20260907000001 — the table had zero rows to validate against at all.
-- Re-seeding idempotently; not attempting to explain how they emptied.

insert into emotion_label_vocabulary (value) values
  ('calm'), ('hopeful'), ('frustrated'), ('annoyed'), ('lonely'), ('sad'),
  ('worried'), ('proud'), ('excited'), ('stressed'), ('overwhelmed'),
  ('irritated'), ('amused'), ('happy'), ('discouraged'), ('indifferent'),
  ('amazed'), ('angry'), ('anxious'), ('ashamed'), ('brave'),
  ('content'), ('disappointed'), ('disgusted'), ('embarrassed'),
  ('grateful'), ('guilty'), ('hopeless'), ('jealous'), ('joyful'),
  ('passionate'), ('peaceful'), ('relieved'), ('scared'), ('surprised'),
  ('confident'), ('drained'), ('satisfied')
on conflict (value) do nothing;

insert into emotion_association_vocabulary (value) values
  ('family'), ('education'), ('friends'), ('tasks')
on conflict (value) do nothing;
