/**
 * Request signing, matching src/shared/core/telemetry/Hmac.luau exactly.
 *
 * Node's `crypto` module already implements SHA-256/HMAC correctly — the
 * Luau side had to build it from scratch because Roblox has no hashing
 * primitive, but the backend has no such constraint. What has to match here
 * is the *construction*: `HMAC(secret, "{ts}.{nonce}.{body}")`. If the two
 * sides disagree on that string, every batch fails signature verification
 * forever, and it looks like a network problem, not an auth mismatch —
 * matching the failure mode this project's own comments call out for the
 * SHA-256 implementation itself.
 */

import { createHmac, timingSafeEqual } from "node:crypto";

export function sign(secret: string, timestamp: number, nonce: string, body: string): string {
  const message = `${Math.floor(timestamp)}.${nonce}.${body}`;
  return createHmac("sha256", secret).update(message, "utf8").digest("hex");
}

/**
 * Constant-time comparison. A `===` check on the two hex strings would leak
 * timing information proportional to how many leading characters match,
 * which is exactly the side channel HMAC verification exists to close.
 *
 * `timingSafeEqual` throws on a length mismatch rather than returning false,
 * so an attacker sending a truncated signature must not be allowed to
 * distinguish "wrong length" from "wrong bytes" through an exception either
 * — both cases resolve to `false` here.
 */
export function verify(expected: string, actual: string): boolean {
  const a = Buffer.from(expected, "hex");
  const b = Buffer.from(actual, "hex");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
