// send-crisis-alert-push — ARCHITECTURE.md §2b, §4.
// DB webhook on crisis_events INSERT. Mode-agnostic, always fires,
// highest-priority notification category in the app. No LLM call — the
// message is a static, verified template (_shared/crisis-resources.ts).

import { createAdminClient } from "../_shared/supabase-admin.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { sendApnsPush } from "../_shared/apns.ts";
import {
  CRISIS_ALERT_BODY,
  CRISIS_ALERT_TITLE,
  CRISIS_RESOURCE_CARD,
} from "../_shared/crisis-resources.ts";

interface WebhookPayload {
  type: string;
  table: string;
  record: {
    id: string;
    emotion_log_id: string;
    detection_method: "keyword" | "llm";
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
    .select("family_id")
    .eq("id", record.emotion_log_id)
    .single();

  if (logError || !log) {
    console.error("send-crisis-alert-push: could not load emotion_log", logError);
    return jsonResponse({ error: "log_lookup_failed" }, 500);
  }

  const { data: parentTokens } = await supabase
    .from("device_tokens")
    .select("apns_token, profiles!inner(family_id, role)")
    .eq("profiles.family_id", log.family_id)
    .eq("profiles.role", "parent");

  const tokens = (parentTokens ?? []).map((t) => t.apns_token);
  if (tokens.length === 0) {
    // Still log this loudly — a crisis signal with no way to reach a
    // parent is worth knowing about even if we can't push it. Not
    // building an alternate delivery path (email fallback etc.) here —
    // flagged as a gap, not silently swallowed.
    console.error(
      `send-crisis-alert-push: crisis_event ${record.id} has NO parent device tokens registered — nothing was delivered.`,
    );
    return jsonResponse({ skipped: "no_parent_device_tokens", crisis_event_id: record.id });
  }

  const results = await Promise.allSettled(
    tokens.map((token) =>
      sendApnsPush(token, {
        alertTitle: CRISIS_ALERT_TITLE,
        alertBody: CRISIS_ALERT_BODY,
        pushType: "alert",
        priority: 10,
        customData: {
          type: "crisis_alert",
          crisis_event_id: record.id,
          resource_card: CRISIS_RESOURCE_CARD,
        },
      })
    ),
  );

  const failures = results.filter((r) => r.status === "rejected");
  if (failures.length > 0) {
    console.error("send-crisis-alert-push: some pushes failed", failures);
  }

  return jsonResponse({ ok: true, sent: tokens.length - failures.length, failed: failures.length });
});
