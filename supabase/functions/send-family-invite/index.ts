// send-family-invite — ARCHITECTURE.md §3b.
//
// Companion to accept-family-invite (which redeems the code this
// function mints). Mints a short pairing code (see _shared/pairing-code.ts)
// instead of a UUID token + Universal Link — that link depended on iOS's
// Universal Link handoff working, which turned out unreliable in practice
// (2026-09-07).

import { createAdminClient, createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { formatPairingCodeForDisplay, generatePairingCode } from "../_shared/pairing-code.ts";

const INVITE_EXPIRY_DAYS = 3;
const MAX_CODE_COLLISION_RETRIES = 5;

const INVITE_MESSAGE_TEMPLATES = [
  "Aku lagi coba journaling reflektif buat lebih ngerti gimana kita komunikasi selama ini. " +
    "Kalau kamu penasaran atau mau coba versi kamu sendiri, buka Gema terus masukin kode ini ya — nggak ada tekanan, kapan pun kamu siap.",
  "Belakangan aku mulai nyoba nulis reflektif soal gimana kita ngobrol selama ini. " +
    "Kalau kamu mau ikut coba versi kamu sendiri, ini kodenya — santai aja, gak perlu buru-buru.",
  "Aku lagi belajar lebih peka soal cara aku komunikasi ke kamu. " +
    "Kalau kamu tertarik nyoba versi kamu sendiri, buka Gema terus masukin kode ini — nggak ada paksaan, kapan pun kamu mau.",
];

function pickInviteMessage(): string {
  const i = Math.floor(Math.random() * INVITE_MESSAGE_TEMPLATES.length);
  return INVITE_MESSAGE_TEMPLATES[i];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonResponse({ error: "Missing Authorization header" }, 401);

  const userClient = createUserClient(authHeader);
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

  const { data: callerProfile } = await userClient
    .from("profiles")
    .select("role, family_id")
    .eq("id", user.id)
    .single();

  if (!callerProfile || callerProfile.role !== "parent") {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const admin = createAdminClient();
  const expiresAt = new Date(Date.now() + INVITE_EXPIRY_DAYS * 24 * 60 * 60 * 1000);

  let invite = null;
  let lastError = null;
  for (let attempt = 0; attempt < MAX_CODE_COLLISION_RETRIES; attempt++) {
    const code = generatePairingCode();
    const { data, error } = await admin
      .from("invites")
      .insert({
        family_id: callerProfile.family_id,
        invited_role: "child",
        invited_by: user.id,
        token: code,
        expires_at: expiresAt.toISOString(),
      })
      .select()
      .single();

    if (!error) {
      invite = data;
      break;
    }
    lastError = error;
    if (error.code !== "23505") break; // only retry on a code collision
  }

  if (!invite) {
    console.error("send-family-invite: could not create invite row", lastError);
    return jsonResponse({ error: "invite_creation_failed" }, 500);
  }

  return jsonResponse({
    ok: true,
    invite_id: invite.id,
    pairing_code: formatPairingCodeForDisplay(invite.token),
    invite_message: pickInviteMessage(),
    expires_at: invite.expires_at,
  });
});
