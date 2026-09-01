// accept-family-invite — ARCHITECTURE.md §3b, §4.
// Called right after a newly-invited child completes auth, carrying the
// invite token from the shared link. Service-role: the invitee has no
// profiles row yet, so there's no RLS path that would let them create one
// themselves — validating the token IS the authorization check here, done
// entirely inside this function rather than via RLS.

import { createAdminClient, createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

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

  const { data: invite, error: inviteError } = await admin
    .from("invites")
    .select("id, family_id, invited_email, invited_role, status, expires_at")
    .eq("token", body.token)
    .single();

  if (inviteError || !invite) {
    return jsonResponse({ error: "invalid_token" }, 404);
  }
  if (invite.status !== "pending") {
    return jsonResponse({ error: `invite_already_${invite.status}` }, 409);
  }
  if (new Date(invite.expires_at) < new Date()) {
    await admin.from("invites").update({ status: "expired" }).eq("id", invite.id);
    return jsonResponse({ error: "invite_expired" }, 409);
  }
  if (
    invite.invited_email &&
    invite.invited_email.toLowerCase() !== (user.email ?? "").toLowerCase()
  ) {
    return jsonResponse({ error: "email_mismatch" }, 403);
  }

  const { error: profileError } = await admin.from("profiles").insert({
    id: user.id,
    family_id: invite.family_id,
    role: invite.invited_role,
    display_name: body.display_name || "Anak",
  });

  if (profileError) {
    console.error("accept-family-invite: profile insert failed", profileError);
    return jsonResponse({ error: "profile_creation_failed" }, 500);
  }

  await admin.from("invites").update({ status: "accepted" }).eq("id", invite.id);

  return jsonResponse({ ok: true, family_id: invite.family_id });
});
