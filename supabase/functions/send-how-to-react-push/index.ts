// send-how-to-react-push — ARCHITECTURE.md §4, §5, §3c.
// DB webhook on how_to_react_tips INSERT. Mode-agnostic: fires whether the
// row came from generate-how-to-react (server mode) or a client writing it
// directly (on_device mode) — this function doesn't care which, it just
// reacts to the row existing. No LLM call here.
//
// Sends both a visible alert and content-available:1, and puts the tip
// text directly in the payload so the app can refresh the widget's
// display cache without an extra fetch (§3c).

import { createAdminClient } from "../_shared/supabase-admin.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { sendApnsPush } from "../_shared/apns.ts";

interface WebhookPayload {
  type: string;
  table: string;
  record: {
    id: string;
    emotion_log_id: string;
    tip: string;
  };
}

Deno.serve(async (req: Request) => {
  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const record = payload.record;
  const supabase = createAdminClient();

  const { data: log, error: logError } = await supabase
    .from("emotion_logs")
    .select("child_id, family_id")
    .eq("id", record.emotion_log_id)
    .single();

  if (logError || !log) {
    console.error("send-how-to-react-push: could not load emotion_log", logError);
    return jsonResponse({ error: "log_lookup_failed" }, 500);
  }

  const [{ data: childProfile }, { data: parentTokens }] = await Promise.all([
    supabase.from("profiles").select("display_name").eq("id", log.child_id).single(),
    supabase
      .from("device_tokens")
      .select("apns_token, profiles!inner(family_id, role)")
      .eq("profiles.family_id", log.family_id)
      .eq("profiles.role", "parent"),
  ]);

  const childName = childProfile?.display_name ?? "Anak";
  const tokens = (parentTokens ?? []).map((t) => t.apns_token);

  if (tokens.length === 0) {
    return jsonResponse({ skipped: "no_parent_device_tokens" });
  }

  const results = await Promise.allSettled(
    tokens.map((token) =>
      sendApnsPush(token, {
        alertTitle: `Catatan baru dari ${childName}`,
        alertBody: record.tip,
        contentAvailable: true,
        customData: { type: "how_to_react_tip", tip: record.tip, child_name: childName },
      })
    ),
  );

  const failures = results.filter((r) => r.status === "rejected");
  if (failures.length > 0) {
    console.error("send-how-to-react-push: some pushes failed", failures);
  }

  return jsonResponse({ ok: true, sent: tokens.length - failures.length, failed: failures.length });
});
