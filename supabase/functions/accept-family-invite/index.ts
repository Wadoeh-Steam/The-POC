// accept-family-invite — ARCHITECTURE.md §3b, §4.
// Called right after a newly-invited child completes auth, carrying the
// pairing code they typed in. Service-role: the invitee has no profiles
// row yet, so there's no RLS path that would let them create one
// themselves — validating the code IS the authorization check here, done
// entirely inside this function rather than via RLS.

import { createAdminClient, createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { normalizePairingCode } from "../_shared/pairing-code.ts";

const ATTEMPT_CAP = 10;
const ATTEMPT_WINDOW_MS = 60 * 60 * 1000; // 1 hour

interface RequestBody {
  token: string;
  display_name: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonResponse({ error: "Missing Authorization header" }, 401);

  // Confirm there's a real, freshly-authenticated user — but everything
  // after this point uses the admin client, since this user has no
  // profile/family yet for RLS to scope against.
  const userClient = createUserClient(authHeader);
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }
  if (!body.token) return jsonResponse({ error: "token is required" }, 400);

  const admin = createAdminClient();

  // Brute-force guard, keyed by caller since most guesses won't match a
  // real invite row (see 20260907000009's migration comment).
  const { data: attemptRow } = await admin
    .from("invite_redemption_attempts")
    .select("failed_attempts, window_started_at")
    .eq("user_id", user.id)
    .single();

  const windowExpired = attemptRow &&
    Date.now() - new Date(attemptRow.window_started_at).getTime() > ATTEMPT_WINDOW_MS;

  if (attemptRow && !windowExpired && attemptRow.failed_attempts >= ATTEMPT_CAP) {
    return jsonResponse({ error: "too_many_attempts" }, 429);
  }

  const recordFailedAttempt = async () => {
    if (!attemptRow || windowExpired) {
      await admin.from("invite_redemption_attempts").upsert({
        user_id: user.id,
        failed_attempts: 1,
        window_started_at: new Date().toISOString(),
      });
    } else {
      await admin
        .from("invite_redemption_attempts")
        .update({ failed_attempts: attemptRow.failed_attempts + 1 })
        .eq("user_id", user.id);
    }
  };

  const code = normalizePairingCode(body.token);

  const { data: invite, error: inviteError } = await admin
    .from("invites")
    .select("id, family_id, invited_email, invited_role, status, expires_at")
    .eq("token", code)
    .single();

  if (inviteError || !invite) {
    await recordFailedAttempt();
    return jsonResponse({ error: "invalid_token" }, 404);
  }
  if (invite.status !== "pending") {
    await recordFailedAttempt();
    return jsonResponse({ error: `invite_already_${invite.status}` }, 409);
  }
  if (new Date(invite.expires_at) < new Date()) {
    await admin.from("invites").update({ status: "expired" }).eq("id", invite.id);
    await recordFailedAttempt();
    return jsonResponse({ error: "invite_expired" }, 409);
  }
  if (
    invite.invited_email &&
    invite.invited_email.toLowerCase() !== (user.email ?? "").toLowerCase()
  ) {
    await recordFailedAttempt();
    return jsonResponse({ error: "email_mismatch" }, 403);
  }

  // Retries on 23503 — the auth.users row this caller just created can
  // occasionally not yet be visible to this INSERT's FK check.
  let profileError: { code?: string; message?: string } | null = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const { error } = await admin.from("profiles").insert({
      id: user.id,
      family_id: invite.family_id,
      role: invite.invited_role,
      display_name: body.display_name || "Anak",
    });
    profileError = error;
    if (!error || error.code !== "23503" || attempt === 2) break;
    await new Promise((resolve) => setTimeout(resolve, 400 * (attempt + 1)));
  }

  if (profileError) {
    console.error("accept-family-invite: profile insert failed", profileError);
    return jsonResponse({ error: "profile_creation_failed", code: profileError.code }, 500);
  }

  await admin.from("invites").update({ status: "accepted" }).eq("id", invite.id);
  await admin.from("invite_redemption_attempts").delete().eq("user_id", user.id);

  return jsonResponse({ ok: true, family_id: invite.family_id });
});
