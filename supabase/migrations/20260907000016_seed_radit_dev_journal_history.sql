-- Seed ~3 weeks of realistic journal history for Radit's dev child account
-- (37675f4a-ec68-4e43-8014-9d8608995d4b), same pattern as
-- 20260907000013's seed for anak yoda. Webhooks disabled for the bulk
-- insert (see that migration's comment for why) and re-enabled after.

alter table emotion_logs disable trigger on_emotion_log_context_complete;
alter table emotion_logs disable trigger on_emotion_log_needs_summary;

do $$
declare
  v_child_id uuid := '37675f4a-ec68-4e43-8014-9d8608995d4b';
  v_family_id uuid := 'f1df3740-b734-4f1d-816f-5387c7136739';
  v_entry_id uuid;
begin
  -- 1. 20 days ago — proud after finishing a school project
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '20 days', 'dailyMood', 0.7, array['proud','happy'], array['Sekolah'], true,
    'Anak Anda merasa bangga karena berhasil menyelesaikan tugas kelompok sekolah tepat waktu.',
    now() - interval '20 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Akhirnya kelar juga tugas kelompok yang ribet itu.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Lega banget, sempet mikir bakal telat ngumpulinnya.', 'Wah keren! Terus gimana rasanya?', 'manual', 1);

  -- 2. 17 days ago — overwhelmed, too many tasks at once
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '17 days', 'dailyMood', -0.5, array['overwhelmed','stressed'], array['Tugas Rumah'], true,
    'Anak Anda merasa kewalahan karena banyak tugas sekolah menumpuk dalam waktu bersamaan.',
    now() - interval '17 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Banyak banget PR numpuk bareng minggu ini.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Bingung mau mulai dari mana dulu.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1);

  -- 3. 14 days ago — content, quiet weekend
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '14 days', 'dailyMood', 0.4, array['content','calm'], array['Keluarga'], true,
    'Hari ini terasa tenang bagi anak Anda, menghabiskan akhir pekan santai di rumah bersama keluarga.',
    now() - interval '14 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Santai aja, seharian di rumah nonton bareng keluarga.', 'Gimana harimu hari ini?', 'manual', 0);

  -- 4. 11 days ago — jealous seeing a friend get an opportunity
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '11 days', 'dailyMood', -0.4, array['jealous','disappointed'], array['Teman'], true,
    'Anak Anda merasa iri melihat temannya terpilih untuk kesempatan yang sebenarnya juga diinginkannya.',
    now() - interval '11 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Temen aku kepilih jadi ketua acara, aku juga pengen sebenernya.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Ngerasa kurang diliat padahal udah usaha juga.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1);

  -- 5. 8 days ago — excited about an upcoming trip
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '8 days', 'dailyMood', 0.9, array['excited','happy'], array['Keluarga'], true,
    'Anak Anda merasa sangat senang menantikan rencana liburan keluarga yang akan datang.',
    now() - interval '8 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Seneng banget, katanya kita mau liburan bulan depan!', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Udah kebayang serunya jalan-jalan bareng keluarga.', 'Wah keren! Terus gimana rasanya?', 'manual', 1);

  -- 6. 6 days ago — embarrassed after a mistake in class
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '6 days', 'dailyMood', -0.5, array['embarrassed','discouraged'], array['Sekolah'], true,
    'Anak Anda merasa malu setelah membuat kesalahan kecil di depan kelas dan masih memikirkannya.',
    now() - interval '6 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Tadi salah jawab di depan kelas, malu banget.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Takut diketawain temen-temen padahal udah lewat.', 'Kira-kira kenapa kamu ngerasa begitu?', 'manual', 1),
    (v_entry_id, 'FEELING', 'Pengen lebih pede lagi kalau jawab di depan kelas.', 'Ada yang pengen kamu coba beda abis ini?', 'manual', 2);

  -- 7. 4 days ago — relieved after resolving the earlier task overload
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '4 days', 'dailyMood', 0.6, array['relieved','satisfied'], array['Tugas Rumah'], true,
    'Anak Anda merasa lega karena akhirnya berhasil menyelesaikan semua tugas yang sempat menumpuk.',
    now() - interval '4 days')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Akhirnya semua PR yang numpuk kelar semua.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Lega rasanya, nggak ada beban lagi buat besok.', 'Terus itu ngaruh ke gimana kamu liat dia sekarang?', 'manual', 1);

  -- 8. Yesterday — hopeful about trying out for a school team
  insert into emotion_logs (child_id, family_id, "timestamp", kind, valence, labels, associations, context_complete, parent_facing_summary, created_at)
  values (v_child_id, v_family_id, now() - interval '1 day', 'dailyMood', 0.7, array['hopeful','confident'], array['Sekolah'], true,
    'Anak Anda merasa optimis dan percaya diri menjelang seleksi tim sekolah yang akan diikutinya.',
    now() - interval '1 day')
  returning id into v_entry_id;
  insert into log_context_answers (emotion_log_id, field, answer, question_text, source, sequence) values
    (v_entry_id, 'FEELING', 'Besok ada seleksi tim sekolah, udah latihan lumayan.', 'Gimana harimu hari ini?', 'manual', 0),
    (v_entry_id, 'FEELING', 'Optimis bisa lolos, udah usaha semaksimal mungkin.', 'Wah keren! Terus gimana rasanya?', 'manual', 1);
end $$;

alter table emotion_logs enable trigger on_emotion_log_context_complete;
alter table emotion_logs enable trigger on_emotion_log_needs_summary;
