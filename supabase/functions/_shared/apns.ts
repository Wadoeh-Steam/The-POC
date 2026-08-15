// Apple Push Notification service — JWT (ES256) provider auth + HTTP/2 send.
// See ARCHITECTURE.md §5. Secrets needed (set via `supabase secrets set`):
//   APNS_KEY_ID        — Key ID of the .p8 Auth Key
//   APNS_TEAM_ID       — Apple Developer Team ID
//   APNS_BUNDLE_ID     — app's bundle identifier (apns-topic)
//   APNS_PRIVATE_KEY   — full contents of the .p8 file (PEM, incl. BEGIN/END lines)
//   APNS_ENV           — "production" or "sandbox" (defaults to "sandbox")

function base64UrlEncode(bytes: Uint8Array): string {
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN (.*)-----/, "")
    .replace(/-----END (.*)-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes.buffer;
}

let cachedKey: CryptoKey | null = null;
async function getSigningKey(): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  const pem = Deno.env.get("APNS_PRIVATE_KEY");
  if (!pem) throw new Error("APNS_PRIVATE_KEY secret not set");
  cachedKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return cachedKey;
}

// Reused across warm invocations of the same Edge Function isolate — Apple
// allows reusing a provider token for up to ~1hr, no need to mint one per push.
let cachedJwt: { token: string; issuedAt: number } | null = null;

async function getProviderToken(): Promise<string> {
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  if (!keyId || !teamId) {
    throw new Error("APNS_KEY_ID / APNS_TEAM_ID secret not set");
  }

  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.issuedAt < 40 * 60) {
    return cachedJwt.token;
  }

  const header = { alg: "ES256", kid: keyId };
  const claims = { iss: teamId, iat: now };

  const encoder = new TextEncoder();
  const headerB64 = base64UrlEncode(encoder.encode(JSON.stringify(header)));
  const claimsB64 = base64UrlEncode(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  const key = await getSigningKey();
  // Web Crypto's ECDSA signature output is the raw r||s concatenation —
  // exactly the format JWS ES256 expects, no DER-to-raw conversion needed.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(signingInput),
  );

  const token = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
  cachedJwt = { token, issuedAt: now };
  return token;
}

export interface ApnsPayload {
  alertTitle: string;
  alertBody: string;
  /** Wakes the app briefly to refresh the widget cache — ARCHITECTURE.md §3c. */
  contentAvailable?: boolean;
  /** "alert" (visible) vs "background" (silent-only). Default "alert". */
  pushType?: "alert" | "background";
  /** Extra fields the app needs on receipt (e.g. tip text for the widget cache). */
  customData?: Record<string, unknown>;
  priority?: 5 | 10;
}

export async function sendApnsPush(
  deviceToken: string,
  payload: ApnsPayload,
): Promise<{ ok: boolean; status: number; body?: string }> {
  const bundleId = Deno.env.get("APNS_BUNDLE_ID");
  if (!bundleId) throw new Error("APNS_BUNDLE_ID secret not set");
  const env = Deno.env.get("APNS_ENV") ?? "sandbox";
  const host = env === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";

  const jwt = await getProviderToken();

  const aps: Record<string, unknown> = {
    alert: { title: payload.alertTitle, body: payload.alertBody },
  };
  if (payload.contentAvailable) aps["content-available"] = 1;

  const body = JSON.stringify({ aps, ...payload.customData });

  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": payload.pushType ?? "alert",
      "apns-priority": String(payload.priority ?? 10),
    },
    body,
  });

  if (!res.ok) {
    const text = await res.text().catch(() => undefined);
    return { ok: false, status: res.status, body: text };
  }
  return { ok: true, status: res.status };
}
