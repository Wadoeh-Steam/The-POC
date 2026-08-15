// Static, verified crisis resources — NEVER LLM-generated. See
// ARCHITECTURE.md §2b and ADR-0006 for why: the stakes of a hallucinated
// or mis-composed crisis response are too high to trust either Gemini or
// the on-device model to write this message.
//
// Contacts verified 2026-08-14 (ARCHITECTURE.md §2b) — re-verify
// periodically, a wrong number here is actively harmful. If this file is
// the only place these are written down, it's also the only place that
// needs updating when a number changes — keep it that way, don't copy
// these strings anywhere else (push payload, in-app "get help" screen,
// etc. should all import from here).

export const CRISIS_ALERT_TITLE = "Perlu perhatian segera";

export const CRISIS_ALERT_BODY =
  "Ada tanda yang perlu perhatian segera dari catatan anak Anda. Ketuk untuk melihat kontak bantuan.";

export const CRISIS_RESOURCE_CARD = {
  headline: "Anak Anda mungkin membutuhkan dukungan segera",
  body:
    "Sebuah catatan dari anak Anda menunjukkan tanda yang perlu perhatian serius. " +
    "Ini bukan diagnosis — tapi kami sarankan Anda menghubungi salah satu layanan berikut sesegera mungkin, " +
    "dan mendekati anak Anda dengan tenang dan penuh perhatian.",
  contacts: [
    {
      name: "SEJIWA (Kemenkes)",
      detail: "Telepon 119, lalu tekan ext. 8. Gratis, 24 jam.",
      note: "Beberapa pengguna melaporkan respons lambat — coba juga opsi lain di bawah jika sulit tersambung.",
    },
    {
      name: "LISA Helpline (Love Inside Suicide Awareness)",
      detail: "0811-3855-472. Gratis, 24/7, melayani seluruh Indonesia.",
    },
    {
      name: "Puskesmas atau UGD rumah sakit terdekat",
      detail: "Datang langsung jika situasinya mendesak.",
    },
  ],
};
