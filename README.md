# EmotionPOC

> ⚠️ **Status: masih tahap eksplorasi (Proof of Concept / POC), bukan produk jadi.**
> Semua dokumen, desain, dan kode di repo ini masih bisa berubah — sebagian
> bahkan bisa dirombak total — sebelum (kalau) proyek ini lanjut ke tahap
> pembangunan produk sungguhan. Anggap semua isi repo ini sebagai catatan
> kerja & eksperimen, bukan keputusan final.

## Apa ini?

EmotionPOC adalah eksplorasi awal untuk sebuah aplikasi yang membantu **orang
tua memahami perasaan anaknya** dengan lebih baik. Anaknya mencatat suasana
hati/perasaannya secara singkat (mirip mencatat mood harian), lalu aplikasi
mencoba merangkum pola dari catatan-catatan itu untuk orang tua — bukan
membocorkan isi catatan pribadi anak apa adanya, tapi memberi gambaran umum
dan saran, dengan bahasa yang hati-hati dan tidak menghakimi.

Target penggunanya adalah keluarga Indonesia, jadi semua hasil yang
ditampilkan ke orang tua ditulis dalam Bahasa Indonesia.

## Kenapa masih disebut "POC"?

Belum ada aplikasi yang bisa dipakai sehari-hari. Yang sedang dikerjakan
sekarang baru:

1. **Merancang** bagaimana sistemnya seharusnya bekerja (data apa yang
   disimpan, siapa boleh lihat apa, dst).
2. **Menguji coba** bagian paling berisiko dari rancangan itu — misalnya,
   apakah AI-nya sebaiknya berjalan di server atau langsung di HP, dan mana
   yang lebih cepat/lebih murah/lebih pas untuk privasi.
3. Membangun **alat uji coba internal** (bukan aplikasi final) untuk
   membandingkan kedua pendekatan itu memakai data contoh (bukan data
   pengguna sungguhan).

Semua ini dilakukan **sebelum** memutuskan untuk benar-benar membangun
aplikasinya, supaya keputusan besar (misalnya: server vs on-device) sudah
punya dasar dari percobaan nyata, bukan cuma tebakan.

## Progress sejauh ini (ringkas)

- ✅ Rancangan arsitektur sistem sudah ditulis (masih bisa berubah)
- ✅ Server percobaan (backend) sudah dijalankan di lingkungan uji coba
  privat — belum untuk publik, belum ada pengguna sungguhan
- ✅ Sudah dibandingkan: menjalankan AI lewat server vs langsung di HP
  (on-device) — lihat hasil kecepatannya di alat uji coba internal
  (`EmotionPOC` app) atau di `PERFORMANCE_COMPARISON.md`
- ⬜ Aplikasi iOS yang sebenarnya (yang dipakai orang tua & anak
  sehari-hari) **belum dibuat** — ini baru direncanakan

## Struktur folder (untuk yang penasaran, tidak perlu ngerti kode)

| Folder/File | Isinya apa |
|---|---|
| `ARCHITECTURE.md` | Dokumen teknis: bagaimana sistem ini dirancang bekerja |
| `PLAN.md` | Rencana pengerjaan & status tiap bagian |
| `PERFORMANCE_COMPARISON.md` | Hasil uji kecepatan AI (server vs on-device) |
| `docs/adr/` | Catatan alasan di balik keputusan-keputusan besar |
| `EmotionPOC/` | Kode alat uji coba internal (bukan aplikasi final) |
| `supabase/` | Kode server percobaan (database, fungsi backend) |

Dokumen-dokumen di atas ditulis untuk pembaca teknis (developer), jadi kalau
dibuka mungkin akan terasa berat — README ini yang dimaksudkan untuk
pembaca non-teknis.

## Yang penting untuk diingat

- Data yang dipakai untuk semua percobaan di atas adalah **data contoh
  (dummy)**, bukan data keluarga sungguhan.
- Arah produk, fitur, bahkan pendekatan teknisnya **masih bisa berubah
  kapan saja** — ini bagian normal dari tahap eksplorasi.
- Belum ada jaminan semua yang tertulis di dokumen-dokumen teknis di atas
  akan benar-benar dibangun persis seperti itu.
