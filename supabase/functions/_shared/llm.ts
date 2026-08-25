// LLM client — OpenRouter (OpenAI-compatible), not a direct Gemini client.
// Supersedes the earlier gemini.ts written when the plan was to call
// Google's API directly — see ADR-0010. Model choice is per-task and
// configurable via env var (see the OPENROUTER_MODEL_* secrets below),
// not hardcoded, since picking the right model per task is exactly what
// OpenRouter makes cheap to A/B — see PERFORMANCE_COMPARISON.md for the
// Phase 0 precedent (BenchmarkCLI already does this kind of comparison
// for on-device vs server; the same harness is the natural place to
// extend for model-vs-model comparisons through OpenRouter).

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

interface LlmCallOptions {
  model: string;
  temperature?: number;
  maxOutputTokens?: number;
  /** Pass a JSON Schema to force structured output (OpenRouter normalizes
   * this across providers, though actual enforcement still depends on
   * whether the routed provider/model supports it — see parseJsonResponse's
   * stripFences fallback for when it doesn't). */
  jsonSchema?: { name: string; schema: Record<string, unknown> };
  /** Injected as a system message when set. Exists specifically for
   * Nemotron's `/no_think` convention (model-specific, not a generic
   * OpenRouter param — the `reasoning: {enabled: false}` API parameter
   * barely helped: 36.5s → 14.3s with 587 reasoning tokens still spent.
   * `/no_think` cut it to ~2-7s with 0 reasoning tokens, see ADR-0010 and
   * PERFORMANCE_COMPARISON.md §8). Re-evaluate if OPENROUTER_MODEL_* env
   * vars point this at a different model — this string means nothing to
   * a non-Nemotron model. */
  systemPrompt?: string;
}

export interface LlmResult {
  text: string;
  promptTokens: number;
  outputTokens: number;
}

export async function callLlm(
  prompt: string,
  opts: LlmCallOptions,
): Promise<LlmResult> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) {
    throw new Error("OPENROUTER_API_KEY secret not set");
  }

  const messages: { role: string; content: string }[] = [];
  if (opts.systemPrompt) {
    messages.push({ role: "system", content: opts.systemPrompt });
  }
  messages.push({ role: "user", content: prompt });

  const body: Record<string, unknown> = {
    model: opts.model,
    messages,
    temperature: opts.temperature ?? 0.2,
    max_tokens: opts.maxOutputTokens ?? 1024,
  };

  if (opts.jsonSchema) {
    body.response_format = {
      type: "json_schema",
      json_schema: {
        name: opts.jsonSchema.name,
        strict: true,
        schema: opts.jsonSchema.schema,
      },
    };
  }

  const res = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
      // Optional attribution headers OpenRouter uses for its public
      // rankings/analytics — not required for auth, safe to omit, kept
      // here since they're free and OpenRouter's docs recommend them.
      "HTTP-Referer": Deno.env.get("OPENROUTER_APP_URL") ?? "https://emotionpoc.app",
      "X-Title": "EmotionPOC",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errBody = await res.text();
    throw new Error(`OpenRouter HTTP ${res.status} (model=${opts.model}): ${errBody}`);
  }

  const data = await res.json();
  const text = data?.choices?.[0]?.message?.content ?? "";
  if (!text) {
    throw new Error(`Empty response from OpenRouter (model=${opts.model})`);
  }

  return {
    text,
    promptTokens: data?.usage?.prompt_tokens ?? 0,
    outputTokens: data?.usage?.completion_tokens ?? 0,
  };
}

/** Fallback cleanup for providers that don't honor json_schema strictly and
 * wrap their output in a markdown fence anyway — same issue the Phase 0
 * POC hit with on-device output, see PERFORMANCE_COMPARISON.md. */
export function stripFences(text: string): string {
  let t = text.trim();
  if (t.startsWith("```")) {
    const firstNewline = t.indexOf("\n");
    t = firstNewline === -1 ? t : t.slice(firstNewline + 1);
  }
  if (t.endsWith("```")) {
    t = t.slice(0, -3);
  }
  return t.trim();
}

/** Extracts the first balanced-brace `{...}` substring. Needed for a real
 * failure mode hit during testing (2026-08-15) with the free-tier default
 * model (`nvidia/nemotron-nano-9b-v2:free`, see ADR-0010): it sometimes
 * emits a complete, valid JSON object and then loops generating blank/
 * whitespace tokens indefinitely instead of stopping, until `max_tokens`
 * cuts it off mid-loop — `finish_reason: "length"` even though the actual
 * answer was already complete. Brace-counting (not regex) so it's not
 * fooled by `{`/`}` characters inside string values. */
function extractBalancedJson(text: string): string {
  const start = text.indexOf("{");
  if (start === -1) throw new Error("No JSON object found in response");
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  throw new Error("No balanced JSON object found in response (truncated?)");
}

export function parseJsonResponse<T>(text: string): T {
  try {
    return JSON.parse(text) as T;
  } catch {
    // Order matters: try the markdown-fence case first (cheap, common),
    // then fall back to balanced-brace extraction (handles the
    // trailing-garbage-after-valid-JSON case above).
    try {
      return JSON.parse(stripFences(text)) as T;
    } catch {
      return JSON.parse(extractBalancedJson(text)) as T;
    }
  }
}

// ============================================================================
// Multi-provider fallback: OpenRouter -> Requesty -> Gemini
//
// Added for be1's evaluate-parent-log-followup, which sits in the child/
// parent's real-time guided-journal write path and can't tolerate
// OpenRouter's 50 req/day free-tier cap silently killing the feature with
// no recourse. callLlm() above is untouched and still the only path for
// existing callers (check-log-context, generate-overview, etc.) — this is
// opt-in for new callers, not a replacement.
//
// Ports the fallback logic already verified live in the POC benchmark app
// (ContentView.swift runServerPass, commit b873c63, 2026-08-21): cascade
// on ANY failure (not just 429 — a provider being down or misconfigured
// should fall through too), Requesty reuses the OpenAI-compatible request
// shape (just a different baseURL/model/key, verified against
// router.requesty.ai/v1), Gemini gets its own adapter since Google's API
// shape is genuinely different (not OpenAI-compatible).
// ============================================================================

interface ProviderConfig {
  name: string;
  apiKey: string;
  baseURL: string;
  model: string;
}

async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: number | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timeout after ${ms}ms`)), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

async function callOpenAICompatible(
  prompt: string,
  opts: LlmCallOptions,
  config: ProviderConfig,
): Promise<LlmResult> {
  const messages: { role: string; content: string }[] = [];
  if (opts.systemPrompt) {
    messages.push({ role: "system", content: opts.systemPrompt });
  }
  messages.push({ role: "user", content: prompt });

  const body: Record<string, unknown> = {
    model: config.model,
    messages,
    temperature: opts.temperature ?? 0.2,
    max_tokens: opts.maxOutputTokens ?? 1024,
  };
  if (opts.jsonSchema) {
    body.response_format = {
      type: "json_schema",
      json_schema: { name: opts.jsonSchema.name, strict: true, schema: opts.jsonSchema.schema },
    };
  }

  const res = await fetch(`${config.baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${config.apiKey}`,
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errBody = await res.text();
    throw new Error(`${config.name} HTTP ${res.status} (model=${config.model}): ${errBody}`);
  }

  const data = await res.json();
  const text = data?.choices?.[0]?.message?.content ?? "";
  if (!text) {
    throw new Error(`Empty response from ${config.name} (model=${config.model})`);
  }

  return {
    text,
    promptTokens: data?.usage?.prompt_tokens ?? 0,
    outputTokens: data?.usage?.completion_tokens ?? 0,
  };
}

/** Non-streaming generateContent — unlike ServerGemini.swift's benchmark
 * client, this doesn't need TTFT measurement, so plain generateContent is
 * simpler than SSE here. Gemini has no `/no_think`-style directive (that's
 * Nemotron-specific); opts.systemPrompt is folded into the user turn as a
 * harmless prefix rather than skipped, since Gemini has no separate system
 * role for the flows that currently set it. */
async function callGemini(
  prompt: string,
  opts: LlmCallOptions,
  config: ProviderConfig,
): Promise<LlmResult> {
  const url = `${config.baseURL}/models/${config.model}:generateContent?key=${config.apiKey}`;
  const text = opts.systemPrompt ? `${opts.systemPrompt}\n\n${prompt}` : prompt;
  const body = {
    contents: [{ role: "user", parts: [{ text }] }],
    generationConfig: {
      temperature: opts.temperature ?? 0.2,
      maxOutputTokens: opts.maxOutputTokens ?? 1024,
    },
  };

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errBody = await res.text();
    throw new Error(`Gemini HTTP ${res.status} (model=${config.model}): ${errBody}`);
  }

  const data = await res.json();
  const outText = (data?.candidates?.[0]?.content?.parts ?? [])
    .map((p: { text?: string }) => p.text ?? "")
    .join("");
  if (!outText) {
    throw new Error(`Empty response from Gemini (model=${config.model})`);
  }

  return {
    text: outText,
    promptTokens: data?.usageMetadata?.promptTokenCount ?? 0,
    outputTokens: data?.usageMetadata?.candidatesTokenCount ?? 0,
  };
}

/**
 * Cascades OpenRouter -> Requesty -> Gemini. `totalBudgetMs` is a single
 * wall-clock budget for the WHOLE chain, not per-provider — deliberate,
 * since this is meant for real-time UX paths (guided-journal followup
 * evaluation) where three sequential per-provider timeouts could stack
 * into an unacceptable wait. Once the budget is exhausted, throws instead
 * of trying remaining providers — caller decides what "give up" means
 * (e.g. evaluate-parent-log-followup treats it as "skip the followup").
 */
export async function callLlmWithFallback(
  prompt: string,
  opts: LlmCallOptions,
  totalBudgetMs: number,
): Promise<LlmResult & { provider: string }> {
  const deadline = Date.now() + totalBudgetMs;
  const openAICompatibleProviders: ProviderConfig[] = [
    {
      name: "openrouter",
      apiKey: Deno.env.get("OPENROUTER_API_KEY") ?? "",
      baseURL: "https://openrouter.ai/api/v1",
      model: opts.model,
    },
    {
      name: "requesty",
      apiKey: Deno.env.get("REQUESTY_API_KEY") ?? "",
      baseURL: "https://router.requesty.ai/v1",
      // Requesty's only free model with clean JSON-schema support,
      // verified live against router.requesty.ai/v1/models (2026-08-21) —
      // not opts.model, since that's an OpenRouter model id.
      model: "mistral/leanstral-1-5",
    },
  ];

  let lastError: unknown = new Error("no provider configured");

  for (const config of openAICompatibleProviders) {
    if (!config.apiKey) {
      lastError = new Error(`${config.name}: no API key configured`);
      continue;
    }
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      throw new Error(`LLM fallback chain exceeded budget before trying ${config.name} (last error: ${lastError})`);
    }
    try {
      const result = await withTimeout(callOpenAICompatible(prompt, opts, config), remaining);
      return { ...result, provider: config.name };
    } catch (e) {
      lastError = e;
      console.warn(`[llm-fallback] ${config.name} failed, trying next provider:`, e);
    }
  }

  const geminiKey = Deno.env.get("GEMINI_API_KEY");
  const remaining = deadline - Date.now();
  if (geminiKey && remaining > 0) {
    const geminiConfig: ProviderConfig = {
      name: "gemini",
      apiKey: geminiKey,
      baseURL: "https://generativelanguage.googleapis.com/v1beta",
      model: Deno.env.get("GEMINI_MODEL") ?? "gemini-flash-lite-latest",
    };
    try {
      const result = await withTimeout(callGemini(prompt, opts, geminiConfig), remaining);
      return { ...result, provider: "gemini" };
    } catch (e) {
      lastError = e;
      console.warn("[llm-fallback] gemini failed:", e);
    }
  } else if (!geminiKey) {
    lastError = new Error(`gemini: no API key configured (previous: ${lastError})`);
  }

  throw new Error(`All LLM providers failed or unavailable: ${lastError}`);
}
