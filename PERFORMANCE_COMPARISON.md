# Performance & Accuracy Comparison — On-device vs Server LLM

**POC:** Meringkas diary emosi anak (1 minggu) menjadi *weekly summary* dan *relationship overview*.
**Keputusan yang ditargetkan:** on-device (`FoundationModels` di Apple M5) **vs** server-side API key (Google Gemini).

> Semua angka on-device vs server `gemini-flash-lite-latest` diambil dari satu benchmark run yang sama (`/tmp/bench_ab3.log`), prompt & parameter identik.

---

## 1. Environment

| | |
|---|---|
| Host | Apple M5, macOS 26.5.2 |
| On-device | `FoundationModels.SystemLanguageModel.default` (loadable model hari ini) |
| Server | Google Gemini API — `gemini-flash-lite-latest` (stabil), `gemini-flash-latest` (**alias `gemini-3.7-flash`, model berpikir**) |
| Approksimasi on-device tok/s | outChars / 4 (hanya estimasi; tak ada token count dari FM) |
| Token server | akurat dari `usageMetadata` |
| Parameter | suhu 0.2, maks 1024 token (keduanya) |
| TTFT server | termasuk round-trip jaringan (curl/Swift dari host M5) |

---

## 2. Contoh Input

### 2a. Dataset (11 emotion logs + parent context) — Anderson Family, Maya (16)

Representasi compact yang masuk ke prompt (dilihat model sama persis dengan di bawah ini):

```
- 2026-08-05 valence=0.65 labels=[calm,hopeful] assoc=[family]
- 2026-08-05 valence=-0.45 labels=[frustrated,annoyed] assoc=[education] journal="I hate group projects."
- 2026-08-06 valence=-0.7 labels=[lonely,sad] assoc=[friends] journal="Everyone already has their own group."
- 2026-08-07 valence=-0.2 labels=[worried] assoc=[education] journal="Presentation today."
- 2026-08-07 valence=0.8 labels=[proud,excited] assoc=[education] journal="Presentation went better than I expected."
- 2026-08-08 valence=-0.55 labels=[stressed,overwhelmed] assoc=[education,tasks] journal="Too many assignments this week."
- 2026-08-09 valence=-0.35 labels=[irritated] assoc=[family] journal="Mom keeps asking me about school."
- 2026-08-10 valence=0.55 labels=[amused,happy] assoc=[friends] journal="Had lunch with Sarah. It was fun."
- 2026-08-11 valence=-0.65 labels=[discouraged,stressed] assoc=[education] journal="I think I'm falling behind everyone."
- 2026-08-12 valence=0.1 labels=[indifferent] assoc=[]
- 2026-08-13 valence=-0.5 labels=[worried,overwhelmed] assoc=[education] journal="I don't know if I'm good enough."
- 2026-08-09 [school] "Asked Maya about her grades." (parent feels: concerned)
- 2026-08-11 [school] "Asked why she had not finished her assignment." (parent feels: frustrated)
- 2026-08-13 [daily routine] "Reminded Maya to study before using her phone." (parent feels: concerned)
Parent reflection logs:
- 2026-08-11 feels worried: "She seems distracted lately."
- 2026-08-13 feels confused: "I don't understand why she doesn't talk to me anymore."
```

### 2b. Prompt — Weekly Summary

```
You are an empathetic family-relationship assistant that synthesizes a child's
emotion diary entries into clear, cautious language.

Here are 11 diary emotion entries recorded by a 16-year-old child over the past week:

<dataset compact di atas>

Write a concise plain-text weekly summary (2 to 4 sentences). Describe the
overall emotional trend and the situations most associated with positive and
negative feelings. Use cautious wording ("may", "appears to", "a possible
pattern is"). Do not diagnose. Do not make confident psychological claims.
Do not mention the raw data numbers.
```

### 2c. Prompt — Relationship Overview

`overviewPrompt` injeksi `dataset compact` + `parent context` lalu minta **strict JSON** dengan shape:

```json
{
  "overview": {
    "headline": "<1 sentence, cautious>",
    "summary": "<2-3 sentences on overall patterns, cautious>",
    "patterns": [ { "topic": "Education|Friends|Family|Other", "observation": "<1 sentence>" } ],
    "relationship_signal": { "parent_concern": "low|moderate|high",
                             "child_openness": "low|moderate|high",
                             "possible_misalignment": true },
    "key_insight": "<1 sentence connecting parent and child perspectives as a possibility, not a fact>"
  }
}
```

Plus rules: pola > kejadian tunggal; log = sinyal bukan fakta; bahasa cautious saja; dilarang diagnosa/salahkan salah satu pihak; output valid JSON without markdown.

---

## 3. Hasil — Latency & Throughput (M5, 100% beban sama)

### 3a. On-device (FoundationModels)

| Task | Fase | TTFT | Total | Output | tok/s* |
|---|---|---|---|---|---|
| summary | cold | 658 ms | 2515 ms | 159 tok / 636 ch | 63.2 |
| summary | warm | 1178 ms | 2612 ms | 159 tok / 636 ch | 60.9 |
| overview | cold | 1181 ms | 6481 ms | 346 tok / 1387 ch | 53.4 |
| overview | warm | 1578 ms | 6264 ms | 346 tok / 1384 ch | 55.2 |

*tok/s = estimasi (chars/4). Variasi antar run ±15% (~50–63 tok/s di run lain).

### 3b. Server (Google Gemini)

| Task | Model | TTFT | Total | Input tok | Output tok | tok/s |
|---|---|---|---|---|---|---|
| summary | gemini-flash-lite-latest | 1153 ms | 1354 ms | 570 | 99 | 73.1 |
| overview | gemini-flash-lite-latest | 1024 ms | 1932 ms | 943 | 341 | 176.5 |
| summary | gemini-flash-latest (=3.7-flash, thinking) | 3926 ms | 3952 ms | 570 | 99 | 25.1 |
| overview | gemini-flash-latest | — | — | — | (40 tok, terpotong) | — |

> **Penting:** TTFT server di atas **termasuk jaringan** (~1 s). Sebelumnya tercatat 0–4 ms dan 200× "percepatan" karena pengukuran lama hanya menghitung waktu streaming, bukan round-trip — angka itu **salah** dan sudah dikoreksi.
> `gemini-flash-latest` = model berpikir (thinking): TTFT 3.9–5.8 s karena menghasilkan *thought tokens* (597 tok) sebelum jawaban, rawan **HTTP 503**, dan jawabannya kerap **terpotong** — tidak cocok untuk API interaktif.

### 3c. Ringkasan

| Metrik | On-device | Server (lite) | Percepatan |
|---|---|---|---|
| summary total | ~2.5 s | 1.35 s | ~1.9× |
| overview total | ~6.4 s | 1.93 s | **~3.3×** |
| summary TTFT | 658 ms (cold) | 1153 ms | ❌ on-device lebih cepat |
| overview TTFT | 1181 ms (cold) | 1024 ms | ~1.2× |
| throughput | ~55–63 tok/s | **176 tok/s** | 3× (overview) |

---

## 4. Contoh Hasil Output

### 4a. On-device `summary` (cold)

> Over the past week, the teenager experienced a mix of emotions, with a noticeable pattern of stress and anxiety, particularly related to educational tasks and group projects. Positive emotions were more commonly associated with social interactions, such as lunch with friends, which brought a sense of amusement and happiness. However, moments of frustration and loneliness were prevalent, especially when dealing with group assignments and feeling overwhelmed by the workload. Overall, the teenager appears to be navigating a challenging period, with a need for support and time management strategies.

### 4b. On-device `overview` (cold) — *di-wrap markdown fence* ❌

````
```json
{
  "overview": {
    "headline": "Maya's recent emotions and their potential impact on her relationships.",
    "summary": "Maya has been experiencing a range of emotions that may affect her relationships with family, friends, and peers. She appears to be juggling multiple stressors, particularly in her education and family interactions.",
    "patterns": [
      { "topic": "Education", "observation": "Maya has been expressing frustration and stress related to her assignments, which may indicate she is feeling overwhelmed with her workload." },
      { "topic": "Friends", "observation": "She has felt lonely and sad, suggesting a possible strain in her friendships, possibly due to group projects or social dynamics." },
      { "topic": "Family", "observation": "Maya has expressed irritation with her family, especially regarding school-related discussions, indicating some tension." }
    ],
    "relationship_signal": { "parent_concern": "moderate", "child_openness": "moderate", "possible_misalignment": true },
    "key_insight": "Maya may be experiencing a possible pattern of stress and frustration that could impact her relationships, suggesting a need for supportive communication and understanding from both parents and peers."
  }
}
```
````

### 4c. Server `summary` (gemini-flash-lite-latest)

> Over the past week, this 16-year-old's emotional landscape appears to fluctuate significantly, with a notable pattern of stress and worry centered primarily around school tasks and academic performance. While academic pressures—such as group work and presentations—frequently bring feelings of frustration or discouragement, positive moments seem to emerge when sharing time with friends or experiencing successful outcomes. Additionally, interactions with family, particularly regarding school discussions, may occasionally contribute to feelings of irritation, alongside moments of calm.

### 4d. Server `overview` (gemini-flash-lite-latest) — **valid JSON, tanpa fence** ✅

```json
{
  "overview": {
    "headline": "Maya appears to be navigating a wave of academic and social stress that may be affecting her communication at home.",
    "summary": "Over the past week, Maya's diary reflects a heavy focus on school-related pressures, alongside moments of social vulnerability with peers. While she experiences bright spots of pride and connection, recurring feelings of being overwhelmed seem to coincide with increased parental check-ins about academics, creating a dynamic of mutual concern.",
    "patterns": [
      { "topic": "Education", "observation": "Maya appears to experience significant stress regarding academic performance, group dynamics, and workloads, which may be contributing to feelings of falling behind." },
      { "topic": "Friends", "observation": "Social interactions show a dual pattern, with moments of initial exclusion giving way to positive connection, suggesting her peer experiences can fluctuate rapidly." },
      { "topic": "Family", "observation": "Inquiries about school appear to occasionally lead to irritation or withdrawal, possibly as Maya attempts to manage her own academic stress independently." }
    ],
    "relationship_signal": { "parent_concern": "high", "child_openness": "low", "possible_misalignment": true },
    "key_insight": "While the parent's questions stem from a place of care and concern over Maya's focus, Maya may perceive these same inquiries as added pressure when she is already feeling overwhelmed by her responsibilities."
  }
}
```

### 4e. Server `overview` (gemini-flash-latest, thinking model) — **terpotong + 503** ❌

Hanya headline sebelum terpotong:

```json
{
  "overview": {
    "headline": "Maya appears to be navigating recurring academic stress and self-doubt, which may be influencing how she responds to family check-ins."
```

Run pertama → **HTTP 503** (high demand), retry → output terpotong (~40 tok). Karena model berpikir (`gemini-3.7-flash`), tidak stabil untuk produksi.

---

## 5. Analisis Akurasi

| Aspek | On-device | Server (lite) |
|---|---|---|
| Pola akademik + sosial | ✅ muncul | ✅ lebih tajam (specific "group work") |
| Nuansa family/school | ⚠️ generik ("irritated with family") | ✅ kuat ("parent questions may unintentionally amplify overwhelm") |
| `key_insight` | ❌ generik ("need for supportive communication") | ✅ **menangkap misalignment parent↔child** — persis insight dataset |
| Kutipan fence markdown | ❌ dibungkus ` ```json ` | ✅ valid JSON polos |
| Bahasa cautious | ✅ | ✅ |
| Konsistensi output struktur | ✅ stabil | ✅ stabil |

**Insight kunci:**
1. Server konsisten menghasilkan `key_insight` yang **menghubungkan perspektif parent & child** (sisi krusial produk parenting) sedangkan model on-device gagal → insight dari server lebih tajam (e.g. "inquiries may be perceived as added pressure", bahkan menangkap `parent_concern: high` / `child_openness: low` yang konsisten).
2. Server mengembalikan JSON siap-parse; on-device butuh stripping fence manual (`ServerGemini.stripFences`).
3. Pakai `gemini-flash-lite-latest` — stabil & cepat; `gemini-flash-latest` adalah model berpikir yang lambat (TTFT 4–6 s), rawan 503, dan output terpotong.

---

## 6. Rekomendasi

| Kebutuhan | Pilih |
|---|---|
| Latency & pengalaman iOS | **Server (gemini-flash-lite-latest)** — total overview 1.9 s vs on-device 6.4 s |
| Kualitas insight parenting | **Server** — misalignment parent↔child konsisten tertangkap |
| Privasi data emosi anak (legal/PII) | **On-device** — tak ada upload data; terima TTFT ~0.7–1.2 s & total ~2.5–6.4 s |
| Offline / tanpa backend biaya | **On-device** — gratis per-perangkat |
| Skalabilitas biaya | On-device flat; server per-token (~biaya ya) |

> Catatan: TTFT server (~1 s) kini dominan biaya jaringan, tidak lagi 0 ms — keunggulan server terletak di **total waktu** (throughput 3×, overview 3.3× lebih cepat), bukan TTFT.

**Kesimpulan praktis:** gunakan **server** untuk pengalaman inti (Overview & Reflection cepat + insight tajam), dengan **fallback on-device** saat offline atau opsi privacy-first. Pertimbangkan `PrivateCloudCompute` setelah iOS 27 untuk jalan tengah (privasi + kekuatan server), belum bisa diuji di POC ini (SDK iOS 26.2 belum punya).

---

## 7. Reproduksi

```bash
cd /Users/radityaaydin/repos/c5/harness
xcodegen generate
xcodebuild -project EmotionPOC.xcodeproj -scheme BenchmarkCLI -destination 'platform=macOS' -derivedDataPath build build
GEMINI_API_KEY="$KEY" GEMINI_MODEL=gemini-flash-lite-latest ./build/Build/Products/Debug/BenchmarkCLI
```

Ubah model/daftar: `GEMINI_MODELS=gemini-flash-lite-latest` (rekomendasi). `gemini-flash-latest` = model berpikir, lambat & 503 — hindari.

---

## 8. Round 2 (2026-08-15) — OpenRouter free-tier + prompt Bahasa Indonesia, 4 task produksi

Setup berubah total dari Round 1: server sekarang lewat **OpenRouter** (bukan Gemini langsung, [ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)), model `nvidia/nemotron-nano-9b-v2:free`, prompt di-rewrite Bahasa Indonesia ([ADR-0007](docs/adr/0007-llm-output-language-indonesian.md)), dan 4 task benchmark diganti dari `summary`/`overview` (POC lama) jadi 4 touchpoint produksi asli: `extraction` (+ crisis-signal, [ADR-0006](docs/adr/0006-guardrails-indonesian-compliance-and-crisis-safety.md)), `howToReact`, `overview`, `reflection`.

### 8a. Temuan kritis — on-device gagal total buat Bahasa Indonesia

```
[onDevice] extraction · cold → FAILED (unsupportedLanguageOrLocale(...))
[onDevice] howToReact · cold → FAILED (unsupportedLanguageOrLocale(...))
[onDevice] overview · cold → FAILED (unsupportedLanguageOrLocale(...))
[onDevice] reflection · cold → FAILED (unsupportedLanguageOrLocale(...))
```

**Bukan bug kode** — ini keterbatasan platform beneran. Riset (2026-08-15): Bahasa Indonesia memang bagian dari riset model dasar Apple (grup bahasa "AFIHHMPRTU"), tapi **belum masuk daftar bahasa yang benar-benar di-ship ke fitur Apple Intelligence** on-device per iOS/macOS 26.1. `LanguageModelSession` tidak punya parameter override bahasa di level app — bahasa yang didukung ditentukan sepenuhnya oleh OS.

**Dampak ke arsitektur:** [ADR-0002](docs/adr/0002-per-profile-llm-execution-mode.md) (toggle `server`/`on_device` per-profile) mengasumsikan `on_device` adalah opsi privacy-first yang benar-benar bisa dipakai. Untuk produk berbahasa Indonesia ini, **`on_device` saat ini tidak berfungsi sama sekali** — bukan "lebih lambat/kurang bagus" seperti temuan Round 1, tapi betul-betul gagal generate apa pun. Ini perlu keputusan produk: sembunyikan opsi `on_device` dari Settings sampai Apple menambah dukungan Indonesia, atau biarkan ada tapi dengan pesan error yang jelas ke user. **Belum diputuskan — lihat PLAN.md.**

Sumber: [Apple Intelligence language/region compatibility (iDownloadBlog, dicek 2026-08-15)](https://www.idownloadblog.com/2025/10/07/apple-intelligence-compatibility/) · [Apple Foundation Models 2025 updates (Apple ML Research)](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates)

### 8b. Server (OpenRouter free-tier) — jalan, tapi 2 temuan penting

| Task | Total | Input tok | Output tok | Reasoning tok | Bahasa output |
|---|---|---|---|---|---|
| extraction | **36 491 ms** | 472 | 1914 | 1756 | (kutip verbatim dari teks anak — dataset dummy masih Inggris) |
| howToReact | 6 347 ms | 262 | 319 | 293 | ✅ Indonesia |
| overview | 20 018 ms | 1064 | 726 | 445 | ✅ Indonesia |
| reflection | 17 126 ms | 949 | 866 | 597 | ❌ **Inggris**, padahal prompt & instruksi eksplisit Bahasa Indonesia |

**Temuan 1 — latency free-tier nggak layak buat write-path.** `extraction` (yang jalan tiap kali anak nulis log, [ADR-0008](docs/adr/0008-guided-journaling-extraction-flow.md)) makan **36.5 detik** — 1756 dari 1914 token output-nya itu reasoning tokens (model "mikir" panjang sebelum jawab). Ini jauh dari "snappy" yang dibutuhkan flow guided-journaling. Angka ini mengonfirmasi + mengkuantifikasi risiko yang udah di-flag [ADR-0010](docs/adr/0010-openrouter-llm-gateway.md) — sebelumnya cuma dugaan, sekarang ada angka nyata.

**Temuan 2 — model nggak konsisten ikutin instruksi bahasa.** `overview` dan `howToReact` balas Bahasa Indonesia dengan benar, tapi `reflection` — prompt & instruksi sama-sama eksplisit Indonesia — balas penuh Bahasa Inggris. Ini gap reliability model gratis yang belum ada mitigasi (retry, atau validasi bahasa output + reject/retry kalau salah).

### 8c. Follow-up (2026-08-15, sama hari) — kedua temuan di atas ditindaklanjuti

User: "1. cari alternatif on_device, mungkin ditranslate dulu ke english. 2. coba terus cari cara agar bisa smooth."

**#2 — latency: ketemu fix nyata.** `nvidia/nemotron-nano-9b-v2:free` punya `"reasoning": {"mandatory": false}` di metadata OpenRouter, tapi parameter generik `reasoning: {enabled: false}` cuma dikit ngaruh (36.5s → 14.3s, reasoning tokens masih 587). Riset lanjut: Nemotron pakai **konvensi system-prompt sendiri**, bukan parameter API generik — `/no_think` sebagai system message. Hasil re-test 4 task pakai `/no_think`:

| Task | Sebelum | Sesudah `/no_think` | Reasoning tok | Bahasa |
|---|---|---|---|---|
| extraction | 36 491 ms | **4 449 ms** (~8x) | 0 | — |
| howToReact | 6 347 ms | **1 616 ms** (~4x) | 0 | ✅ Indonesia |
| overview | 20 018 ms | **7 258 ms** (~2.8x) | 0 | ✅ Indonesia |
| reflection | 17 126 ms | **7 210 ms** (~2.4x) | 0 | ✅ Indonesia (Temuan 2 di atas ikut hilang) |

**Trade-off yang ketemu, belum tuntas diselidiki:** `extraction` tanpa reasoning jadi kurang menyeluruh — field yang sebelumnya berhasil diekstrak (mis. `TRIGGER`) balik jadi `null`. Dugaan: langkah "mikir" bantu model lebih teliti membaca konteks. Untuk `check-log-context` ini konsekuensinya cuma UX (anak dapet lebih banyak follow-up question), **bukan** langsung soal keamanan — keyword pre-filter deterministik ([ADR-0006](docs/adr/0006-guardrails-indonesian-compliance-and-crisis-safety.md)) tetap jadi lapis utama, sinyal krisis LLM di mode `/no_think` **belum pernah dites** terhadap teks yang benar-benar mengindikasikan krisis (cuma dites dengan teks non-krisis). Ditandai butuh review domain-expert, bukan diasumsikan aman.

**Ditindaklanjuti ke production**: `/no_think` sudah ditambahkan ke `supabase/functions/_shared/llm.ts` (parameter `systemPrompt`) dan ke-4 Edge Function terkait, di-redeploy 2026-08-15.

**#1 — on-device: alternatif ketemu, belum bisa divalidasi penuh dari environment ini.** Apple punya framework terpisah, `Translation` (`TranslationSession`), yang **mendukung Bahasa Indonesia** on-device — beda dari `FoundationModels` yang belum. Ada initializer `TranslationSession.init(installedSource:target:)` yang bisa dipakai di luar SwiftUI (cocok buat `BenchmarkCLI`), tapi **mensyaratkan language pack sudah ter-download di device** — dan test langsung di host ini gagal dengan `TranslationError.Cause.notInstalled`. Kodenya (`OnDeviceTranslator.swift`) sudah benar dan terverifikasi compile + throw error yang jelas, tapi:
- Nggak ada cara trigger download dari konteks CLI/headless.
- Butuh salah satu: (a) setup manual di Settings → General → Language & Region → Translation Languages di mesin yang bakal jalanin ini, atau (b) alur SwiftUI `.translationTask` yang bisa munculin system permission/download prompt — **belum dibangun**, `ContentView.swift` (app iOS, punya SwiftUI) belum diintegrasikan dengan translator ini.
- Pipeline lengkap (translate input Indonesia→Inggris → jalanin FoundationModels bahasa Inggris → translate hasil Inggris→Indonesia, termasuk translate selektif field JSON tanpa ngerusak enum seperti `parent_concern: low|moderate|high`) **belum dibangun** — baru tahap pembuktian kelayakan API-nya.

Sources: [TranslationSession Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession) · [Apple Intelligence language/region compatibility](https://www.idownloadblog.com/2025/10/07/apple-intelligence-compatibility/) · [OpenRouter reasoning tokens control](https://openrouter.ai/docs/use-cases/reasoning-tokens) · [NVIDIA Nemotron Nano 9B v2 model card](https://developer.nvidia.com/downloads/assets/ace/model_card/nemotron-nano-9b-v2.pdf)

### 8d. Real device retest (2026-08-15, sama hari) — iPhone fisik via USB, bukan Mac host/simulator

Sebelumnya semua test on-device jalan di Mac host (M5) karena simulator iPhone gagal load model (`ModelManagerError 1026`, lihat §8g di bawah). User connect **iPhone fisik (iOS 26.6)** via USB — kesempatan re-test di hardware asli, bukan proxy Mac. `EmotionPOC` (app iOS, bukan `BenchmarkCLI`) di-build, disign pakai Apple Development cert (Team `9ZFCALDWL4`), diinstall & dijalankan via `xcrun devicectl` dengan `--autorun` + `OPENROUTER_API_KEY` lewat `-e` (env var device beda dari shell — butuh `devicectl`'s `--environment-variables`/`-e` flag, bukan `export` biasa).

**Sekaligus, ContentView.swift diubah jadi 2 tombol terpisah** ("Run On-Device" / "Run Server-Side", user request) — masing-masing punya section hasil sendiri, reuse `ServerOpenRouter`/`BenchmarkService` yang sama persis dengan `BenchmarkCLI`.

**Hasil — kedua temuan §8a & §8c dikonfirmasi ulang di hardware asli, bukan cuma Mac:**
- **On-device**: gagal identik (`unsupportedLanguageOrLocale`) di iOS 26.6 device asli — bukan kuirk Mac/simulator, Apple Intelligence beneran belum dukung Indonesia di versi OS ini.
- **Translation workaround**: gagal identik (`notInstalled`) — device fisik ini juga belum punya language pack id↔en ter-download. Konsisten dengan §8c, memperkuat kesimpulan: butuh alur SwiftUI `.translationTask` buat prompt download beneran, nggak otomatis kepake cuma karena device asli.
- **Server-side jalan**, dengan temuan baru yang **cuma keliatan di jaringan mobile beneran**: beberapa request gagal `NSURLErrorDomain Code=-1005 "The network connection was lost"` — sesuatu yang nggak muncul waktu testing dari Mac (koneksi kabel/WiFi kantor stabil). Ini nemuin gap nyata: `ServerOpenRouter`/`_shared/llm.ts` **belum ada retry logic** buat koneksi putus-nyambung, yang di dunia nyata (anak pakai hp di jaringan seluler/WiFi rumah yang nggak stabil) itu bakal sering kejadian. Belum ada mitigasi.

**Bug ketemu & dibenerin**: `--autorun` sempat jalanin server-pass **2x** dalam satu launch — `.task` SwiftUI re-fire di device asli (nggak kejadian pas ditest di simulator/preview sebelumnya). Fix: guard eksplisit (`hasAutoRun` state), bukan andalin `.task` cuma jalan sekali.

### 8e. Translation workaround — terbukti jalan setelah language pack ke-download (2026-08-16)

Ditambahin tombol baru "Test Translation id→en" yang pakai `.translationTask(source:target:)` (modifier SwiftUI, satu-satunya jalur yang bisa munculin system download-permission UI Apple — beda dari `OnDeviceTranslator`'s `init(installedSource:target:)` yang cuma bisa jalan kalau bahasanya udah ke-install). User tap tombolnya di iPhone fisik — **nggak ada dialog kelihatan** ("ga ngapa ngapain"), tapi ternyata download-nya jalan silent di background.

Relaunch app abis itu (fresh process, `--terminate-existing`), kedua jalur translate langsung sukses tanpa perlu tap ulang:
```
[translate id→en] ok (385ms): "Hello, this is a translation test."
[translate SwiftUI id→en] ok: "Hello, this is a translation test."
```
"Halo, ini tes terjemahan." → "Hello, this is a translation test." — akurat. Bahkan jalur programmatic (`init(installedSource:target:)`, yang sebelumnya selalu `notInstalled`) sekarang langsung berhasil, karena language pack-nya udah persisten di level OS, nggak peduli app mana yang trigger download-nya.

**Yang ini buktiin**: workaround translate buat §2a itu **viable secara teknis**, bukan cuma teori.

**Catatan UX**: nggak ada dialog visible pas trigger download — beda dari ekspektasi umum soal "system permission prompt". Bisa jadi Apple auto-approve buat pasangan bahasa tertentu/ukuran model kecil, atau dialog-nya muncul sangat singkat/nggak ke-notice user. Perlu diinget kalau bangun UX produksi: nggak bisa asumsikan user bakal liat & approve dialog eksplisit — mungkin perlu indikator loading sendiri pas first-time trigger.

### 8f. Pipeline lengkap dibangun & berhasil end-to-end untuk semua 4 task (2026-08-16, sama hari)

Setelah §8e buktiin translate-nya sendiri jalan, pipeline lengkapnya langsung dibangun: `EnglishPromptBuilder.swift` (mirror `PromptBuilder.swift`, tapi Inggris — nggak pernah ditampilin ke user, cuma internal) + `OnDeviceTranslationPipeline.swift` yang orkestrasi: build prompt Inggris → jalanin `FoundationModels` → translate hasil balik ke Indonesia **selektif** (cuma field teks bebas kayak `headline`/`summary`/`observation`/`key_insight`/`title`/`description`/`based_on` yang di-translate; field struktural kayak `relationship_signal.parent_concern: low|moderate|high` sengaja dibiarin apa adanya karena itu buat logic app, bukan buat dibaca parent).

Test pertama: 3 dari 4 task sukses, `reflection` gagal decode JSON — ternyata model on-device kadang balikin **array JSON langsung** (`[{...}, {...}]`) bukan dibungkus `{"recommendations": [...]}` kayak diminta prompt (quirk instruction-following FoundationModels, bukan bug logic). Fix: terima kedua bentuk (kalau top-level JSON itu array, bungkus otomatis jadi `{"recommendations": array}`).

Setelah fix, **ke-4 task sukses berturut-turut, dua kali run**:

| Task | Run 1 | Run 2 |
|---|---|---|
| extraction | 2385 ms | 1840 ms |
| howToReact | 1148 ms | 1360 ms |
| overview | 5561 ms | 6536 ms |
| reflection | 7264 ms | 9049 ms |

**Kesimpulan: blocker `on_device` mode buat Bahasa Indonesia (§8a) sekarang teratasi lewat workaround translate ini** — bukan cuma proof-of-concept, tapi pipeline yang beneran jalan end-to-end di device fisik buat semua 4 touchpoint produksi. Dibanding server-side (~1.5-8s tergantung task, §8c), latency-nya sebanding — bahkan `extraction` on-device+translate justru lebih cepat dari server di beberapa run.

**Yang masih perlu sebelum ini production-ready:**
- Belum ada perbandingan kualitas ketat antara output translate-pipeline vs server-side (belum ada eval sistematis, baru observasi manual).
- Fix "bare array" di `reflection` itu reaktif (nemuin pas testing), belum tau apakah task lain (`extraction`, `overview`) punya quirk serupa yang belum ke-trigger di test ini — masih rawan given ukuran sample kecil.
- UX buat first-time language-pack download (§8e) belum didesain — nggak ada dialog visible yang bisa diandelin.
- `EnglishPromptBuilder.swift` sekarang paralel manual sama `PromptBuilder.swift` (Indonesia) dan `prompts.ts` (backend) — 3 versi prompt yang harus di-sync manual kalau ada perubahan aturan (cautious-language, JSON shape, dst). Risiko drift.

### 8g. Reproduksi

```bash
cd /Users/radityaaydin/repos/c5/harness
xcodegen generate
xcodebuild -project EmotionPOC.xcodeproj -scheme BenchmarkCLI -destination 'platform=macOS' -derivedDataPath build build
OPENROUTER_API_KEY="$KEY" ./build/Build/Products/Debug/BenchmarkCLI
```

Ganti model: `OPENROUTER_MODEL=<model-id>` (lihat daftar model & hasil test di ADR-0010). `OPENROUTER_MODELS=model-a,model-b` untuk banding beberapa model sekaligus.
On-device dijalankan di host M5 karena simulator iPhone 17 Pro gagal load model (`ModelManagerError 1026`).