/**
 * Request signing. Must match backend/src/hmac.ts and
 * src/shared/core/telemetry/Hmac.luau's construction exactly, or every batch
 * fails verification -- see backend/test/hmac.test.ts for why that failure
 * mode is worse than it sounds (it presents as a network problem, not an
 * auth bug). Not re-verified against the Luau vector here: it is the
 * identical five lines already proven correct in backend/src/hmac.ts, and
 * triplicating the same cross-language check a third time tests the copying,
 * not the construction.
 */

import { createHmac } from "node:crypto";

export function sign(secret: string, timestamp: number, nonce: string, body: string): string {
  const message = `${Math.floor(timestamp)}.${nonce}.${body}`;
  return createHmac("sha256", secret).update(message, "utf8").digest("hex");
}
