// send-family-invite — ARCHITECTURE.md §3b. The half of the invite flow
// that was missing from the initial pass: this is what actually creates
// the invites row (with a server-generated token — not client-supplied,
// see the comment on the removed invites INSERT policy in the RLS
// migration) and sends the email via Supabase Auth's admin
// inviteUserByEmail, which only the service role can call.
//
// Companion to accept-family-invite (which redeems the token this
// function mints).

import { createAdminClient, createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

interface RequestBody {
  invited_email: string;
}

const INVITE_EXPIRY_DAYS = 7; // Placeholder — ARCHITECTURE.md §7 open item, not finalized.

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonResponse({ error: "Missing Authorization header" }, 401);

  const userClient = createUserClient(authHeader);
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }
  if (!body.invited_email) return jsonResponse({ error: "invited_email is required" }, 400);

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
      invited_email: body.invited_email,
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

  // Deep-link redirect: the child's device needs to land back in the app
  // (not a browser) after clicking the email link, carrying the token.
  // EMOTIONPOC_APP_REDIRECT_URL should be a configured universal link /
  // custom URL scheme — set as an Edge Function secret, not hardcoded
  // here, since it likely differs between TestFlight/App Store builds.
  const redirectBase = Deno.env.get("EMOTIONPOC_APP_REDIRECT_URL") ??
    "emotionpoc://accept-invite";
  const redirectTo = `${redirectBase}?token=${token}`;

  const { error: emailError } = await admin.auth.admin.inviteUserByEmail(
    body.invited_email,
    { data: { invite_token: token }, redirectTo },
  );

  if (emailError) {
    // Invite row already exists — leave it as 'pending' rather than
    // rolling back, so a retry (or resend, once that's built — §7 open
    // item) doesn't need to recreate it from scratch.
    console.error("send-family-invite: inviteUserByEmail failed", emailError);
    return jsonResponse({ error: "email_send_failed", invite_id: invite.id }, 502);
  }

  return jsonResponse({ ok: true, invite_id: invite.id, expires_at: invite.expires_at });
});
