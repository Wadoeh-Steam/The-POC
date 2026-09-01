// send-family-invite — ARCHITECTURE.md §3b.
//
// Companion to accept-family-invite (which redeems the token this
// function mints).

import { createAdminClient, createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

const INVITE_EXPIRY_DAYS = 7;

const INVITE_MESSAGE_TEMPLATES = [
  "Aku lagi coba journaling reflektif buat lebih ngerti gimana kita komunikasi selama ini. " +
    "Kalau kamu penasaran atau mau coba versi kamu sendiri, klik aja link ini — nggak ada tekanan, kapan pun kamu siap.",
  "Belakangan aku mulai nyoba nulis reflektif soal gimana kita ngobrol selama ini. " +
    "Kalau kamu mau ikut coba versi kamu sendiri, ini linknya — santai aja, gak perlu buru-buru.",
  "Aku lagi belajar lebih peka soal cara aku komunikasi ke kamu. " +
    "Kalau kamu tertarik nyoba versi kamu sendiri, klik link ini ya — nggak ada paksaan, kapan pun kamu mau.",
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
  const token = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + INVITE_EXPIRY_DAYS * 24 * 60 * 60 * 1000);

  const { data: invite, error: insertError } = await admin
    .from("invites")
    .insert({
      family_id: callerProfile.family_id,
      invited_role: "child",
      invited_by: user.id,
      token,
      expires_at: expiresAt.toISOString(),
    })
    .select()
    .single();

  if (insertError) {
    console.error("send-family-invite: could not create invite row", insertError);
    return jsonResponse({ error: "invite_creation_failed" }, 500);
  }

  const redirectBase = Deno.env.get("EMOTIONPOC_APP_REDIRECT_URL") ??
    "emotionpoc://accept-invite";
  const inviteUrl = `${redirectBase}?token=${token}`;

  return jsonResponse({
    ok: true,
    invite_id: invite.id,
    invite_url: inviteUrl,
    invite_message: pickInviteMessage(),
    expires_at: invite.expires_at,
  });
});
