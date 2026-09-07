-- Both vocabulary tables were unexpectedly empty live, including the
-- original seeds from 20260814000001 — re-seeding idempotently.

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
