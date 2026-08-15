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
