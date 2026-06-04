// Minimal shared-password auth. One password (APP_PASSWORD) unlocks the board.
// On success we set an httpOnly cookie holding an HMAC token derived from
// SESSION_SECRET, so the cookie can't be forged without the secret.
//
// Uses Web Crypto (works in both the Edge middleware and Node route handlers).

const COOKIE_NAME = "scopa_session";
const encoder = new TextEncoder();

async function hmac(value: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return Buffer.from(sig).toString("hex");
}

export const SESSION_COOKIE = COOKIE_NAME;

/** Token stored in the cookie when a user is authenticated. */
export async function makeToken(): Promise<string> {
  const secret = process.env.SESSION_SECRET || "dev-insecure-secret";
  return hmac("authenticated", secret);
}

export async function isValidToken(token: string | undefined): Promise<boolean> {
  if (!token) return false;
  const expected = await makeToken();
  // constant-time-ish compare
  if (token.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < token.length; i++) diff |= token.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

export function checkPassword(input: string): boolean {
  const expected = process.env.APP_PASSWORD || "";
  if (!expected) return false;
  if (input.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < input.length; i++) diff |= input.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
