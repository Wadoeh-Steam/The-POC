-- Seed ~3 weeks of realistic journal history for anak yoda
-- (f009fa4e-6497-4dc6-a364-1738f7e9fc51, mama yoda's real paired child) so
-- Ringkasan/overview has actual signal to work with in demos/testing.
-- Also drops the throwaway lookup table from 20260907000012.
--
-- Webhooks disabled for this bulk insert: generate-how-to-react would fire
-- a real push notification per row (backdated test data, not a real
-- moment to alert the parent about), and summarize-child-log-entry would
-- burn a real LLM call per row when this migration already writes
-- realistic parent_facing_summary text directly.

drop table if exists _debug_lookup;

alter table emotion_logs disable trigger on_emotion_log_context_complete;
alter table emotion_logs disable trigger on_emotion_log_needs_summary;

do $$
declare
  v_child_id uuid := 'f009fa4e-6497-4dc6-a364-1738f7e9fc51';
  v_family_id uuid := 'a936d852-f04d-478a-811e-4d14e6e95395';
  v_entry_id uuid;
begin
  -- 1. 19 days ago — excited/happy, won a school basketball match
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '19 days', 'dailyMood', 0.8, array['happy','excited'], array['Sekolah'], true,
    'Hari ini anak Anda merasa sangat senang dan bangga karena timnya menang lomba basket di sekolah, apalagi orang tuanya sempat menonton.',
    now() - interval '19 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Seru banget! Tadi menang lomba basket sama temen-temen.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Bangga banget, apalagi orang tua sempet nonton juga.', 'Wah keren! Terus gimana rasanya menang?', 'manual', 1);

  -- 2. 16 days ago — stressed/anxious about an upcoming exam
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '16 days', 'dailyMood', -0.4, array['stressed','anxious'], array['Nilai Ujian'], true,
    'Anak Anda merasa cemas menjelang ujian minggu depan dan khawatir belum cukup belajar.',
    now() - interval '16 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Agak parno sih mikirin ujian minggu depan.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Takutnya belum cukup belajar buat matematika.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1);

  -- 3. 13 days ago — calm, ordinary day at home
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '13 days', 'dailyMood', 0.5, array['calm','content'], array['Keluarga'], true,
    'Hari ini berjalan tenang bagi anak Anda — cerita soal momen santai bersama keluarga di rumah.',
    now() - interval '13 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Biasa aja, tenang. Tadi masak bareng di rumah.', 'Gimana harimu hari ini?', 'manual', 0);

  -- 4. 10 days ago — frustrated with a friend
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '10 days', 'dailyMood', -0.5, array['frustrated','annoyed'], array['Teman'], true,
    'Anak Anda merasa kesal karena janji main dengan temannya dibatalkan mendadak tanpa kabar.',
    now() - interval '10 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Kesel, janji main sama temen tiba-tiba dibatalin.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Nggak dikabarin dulu, jadi ngerasa nggak dihargain.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1);

  -- 5. 7 days ago — proud after a good grade
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '7 days', 'dailyMood', 0.9, array['proud','happy'], array['Nilai Ujian'], true,
    'Anak Anda merasa bangga karena hasil ujian yang ditakutkan sebelumnya ternyata membuahkan nilai bagus.',
    now() - interval '7 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Nilai ujian matematika keluar, bagus banget!', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Bangga sama diri sendiri, belajarnya kebayar.', 'Wah keren! Terus gimana rasanya?', 'manual', 1);

  -- 6. 5 days ago — lonely, a close friend moved away
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '5 days', 'dailyMood', -0.6, array['lonely','sad'], array['Teman'], true,
    'Anak Anda merasa kesepian karena teman dekatnya baru saja pindah kota.',
    now() - interval '5 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Sepi rasanya, sahabat aku baru aja pindah kota.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Udah biasa cerita apa-apa sama dia, sekarang jadi sepi.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1),
    (v_entry_id, 'FEELING', 'Pengen tetep kontak-kontakan meski jauh.', 'Ada yang pengen kamu coba beda abis ini?', 'manual', 2);

  -- 7. 3 days ago — worried about a family matter
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '3 days', 'dailyMood', -0.3, array['worried','anxious'], array['Keluarga'], true,
    'Anak Anda sedikit khawatir mendengar orang tuanya membicarakan urusan keuangan keluarga.',
    now() - interval '3 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Agak khawatir, denger orang tua ngobrolin soal duit.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Takut ada masalah tapi nggak dikasih tau ke aku.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1);

  -- 8. Yesterday — grateful/hopeful, patched things up with the friend
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '1 day', 'dailyMood', 0.7, array['grateful','hopeful'], array['Teman','Keluarga'], true,
    'Anak Anda merasa lega dan bersyukur setelah berbaikan dengan temannya, dan merasa lebih tenang soal keluarga.',
    now() - interval '1 day')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Udah baikan sama temen yang kemarin itu, lega banget.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Bersyukur masih bisa saling ngobrol baik-baik.', 'Terus itu ngaruh ke gimana kamu liat dia sekarang?', 'manual', 1);
end $$;

alter table emotion_logs enable trigger on_emotion_log_context_complete;
alter table emotion_logs enable trigger on_emotion_log_needs_summary;
