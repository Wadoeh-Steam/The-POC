// check-log-context — ARCHITECTURE.md §3a, §3, §2a.
// Called by the client while the child is still composing an entry, before
// anything is saved. `server` mode only — `on_device` mode never reaches
// this, it calls SystemLanguageModel locally with the same prompt shape
// (see PromptBuilder.swift's Indonesian counterpart, ADR-0007).
//
// Does NOT write to the database — the client owns all writes in this
// flow (including the crisis-triggered early save, §2b). This function
// is inference only.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildExtractionPrompt,
  EXTRACTION_JSON_SCHEMA,
  type ExtractionResult,
  missingFieldsFrom,
} from "../_shared/prompts.ts";

// User decision (2026-08-14): free-tier OpenRouter models for all four LLM
// tasks, including this one — despite it including crisis-signal detection
// (§2b), the single highest-stakes classification in the app. Not a
// substitute for the mandatory keyword pre-filter layer (§2b), which stays
// deterministic and model-independent regardless of this choice. See
// ADR-0010's "Free-tier model swap" section for the original trade-off.
//
// nvidia/nemotron-nano-9b-v2:free (the original pick — a reasoning model
// that burned several hundred tokens "thinking" before the actual JSON,
// an accepted latency cost on the child's write path) was deprecated and
// pulled from OpenRouter entirely (2026-09-07, hard 404). Replaced with
// liquid/lfm-2.5-2.6b:free, which does NOT have that cost — its reasoning
// (if any) stays in a separate response field, content is clean JSON
// directly — verified live against this same schema.
const DEFAULT_MODEL = "liquid/lfm-2.5-2.6b:free";

interface RequestBody {
  valence: number;
  labels: string[];
  associations: string[];
  journal: string | null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "Missing Authorization header" }, 401);
  }

  const supabase = createUserClient(authHeader);
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  if (typeof body.valence !== "number") {
    return jsonResponse({ error: "valence is required" }, 400);
  }

  try {
    const prompt = buildExtractionPrompt({
      valence: body.valence,
      labels: body.labels ?? [],
      associations: body.associations ?? [],
      journal: body.journal ?? null,
    });

    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_EXTRACTION") ?? DEFAULT_MODEL,
      jsonSchema: EXTRACTION_JSON_SCHEMA,
      // "/no_think" (see llm.ts) cut this call from ~36s to ~2-7s in
      // testing (PERFORMANCE_COMPARISON.md §8) — worth it given this is
      // the write-path call. CAVEAT, not yet resolved: with reasoning
      // disabled, extraction looked less thorough in testing (more
      // fields marked null that a reasoning pass had caught) — the
      // crisis_signal check in this same call is only verified against
      // non-crisis test text so far, its reliability under /no_think on
      // actual crisis-indicating language is UNVERIFIED. This is exactly
      // why the deterministic keyword pre-filter (§2b) is the primary
      // safety net, not this LLM check — but flag this for the
      // domain-expert review already required before ship (ADR-0006).
      systemPrompt: "/no_think",
      // maxOutputTokens no longer needs the large reasoning-token
      // headroom (0 reasoning tokens observed with /no_think), but left
      // generous since it's free and costs nothing to keep as a buffer.
      maxOutputTokens: 4000,
    }, 6000); // write-path latency budget, same class as evaluate-parent-log-followup's 5s
    const parsed = parseJsonResponse<ExtractionResult>(result.text);

    return jsonResponse({
      extracted: parsed.extracted,
      missing_fields: missingFieldsFrom(parsed.extracted),
      crisis_signal: parsed.crisis_signal === true,
    });
  } catch (err) {
    console.error("check-log-context failed:", err);
    return jsonResponse({ error: "extraction_failed" }, 502);
  }
});
