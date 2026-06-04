// Minimal shared-password auth. One password (APP_PASSWORD) unlocks the board.
//
// On success we set an httpOnly cookie holding a signed, expiring token:
//   payload   = "<issuedAt>.<nonce>"
//   token     = "<payload>.<HMAC_SHA256(payload, SESSION_SECRET)>"
// The nonce gives each session unique entropy; issuedAt enforces expiry; the
// HMAC means the cookie can't be forged without SESSION_SECRET, and rotating
// the secret invalidates every outstanding session.
//
// Uses Web Crypto so it runs in both the Edge middleware and Node route
// handlers. (Buffer is intentionally avoided for Edge robustness.)

const COOKIE_NAME = "scopa_session";
const encoder = new TextEncoder();
const MAX_AGE_MS = 1000 * 60 * 60 * 24 * 30; // 30 days

export const SESSION_COOKIE = COOKIE_NAME;
export const SESSION_MAX_AGE_SECONDS = Math.floor(MAX_AGE_MS / 1000);

function secret(): string {
  return process.env.SESSION_SECRET || "dev-insecure-secret";
}

function toHex(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, "0");
  return out;
}

async function hmacHex(value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret()),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return toHex(sig);
}

// Constant-time comparison of two hex strings (always 64 chars here, so the
// length check reveals nothing about the secret).
function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Issue a fresh, signed session token. */
export async function makeToken(): Promise<string> {
  const payload = `${Date.now()}.${crypto.randomUUID()}`;
  const sig = await hmacHex(payload);
  return `${payload}.${sig}`;
}

/** Validate signature + expiry of a session token. */
export async function isValidToken(token: string | undefined): Promise<boolean> {
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const [issuedAt, nonce, sig] = parts;
  const expected = await hmacHex(`${issuedAt}.${nonce}`);
  if (!timingSafeEqualHex(sig, expected)) return false;
  const ts = Number(issuedAt);
  if (!Number.isFinite(ts)) return false;
  return Date.now() - ts <= MAX_AGE_MS;
}

/**
 * Verify the submitted password. Both sides are HMAC'd before comparison so
 * the check is constant-time and leaks neither the password nor its length.
 */
export async function checkPassword(input: string): Promise<boolean> {
  const expected = process.env.APP_PASSWORD || "";
  if (!expected) return false; // fail closed when unconfigured
  const [a, b] = await Promise.all([hmacHex(input), hmacHex(expected)]);
  return timingSafeEqualHex(a, b);
}
