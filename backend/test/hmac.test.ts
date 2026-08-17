import { describe, expect, it } from "vitest";
import { sign, verify } from "../src/hmac.js";

describe("hmac.sign", () => {
  it("matches src/shared/core/telemetry/Hmac.luau's construction exactly", () => {
    // Cross-language check. If the two sides disagree on this string, every
    // batch fails verification forever and it presents as a network
    // problem, not an auth bug — the same failure mode the SHA-256
    // implementation's own comments warn about.
    //
    // This value was actually computed by the Luau side, not guessed:
    //   lune run tools/scratch-hmac-vector   (Hmac.signRequest("s", 1000, "abc", "{}"))
    // A first draft of this test hardcoded a value that was never run
    // through Lune; the real one below differs completely. Pinned here so a
    // change to either implementation that breaks the pairing is caught
    // immediately, not discovered against a live game server.
    expect(sign("s", 1000, "abc", "{}")).toBe(
      "10add5574f8d84b0de81a23169790c3e077efe73b1eedd6d013926fd85d29687",
    );
  });

  it("is stable for identical inputs", () => {
    expect(sign("secret", 1700000000, "nonce-1", "body")).toBe(
      sign("secret", 1700000000, "nonce-1", "body"),
    );
  });

  it("changes when any component changes", () => {
    const base = sign("secret", 1700000000, "nonce-1", "{}");
    expect(sign("other", 1700000000, "nonce-1", "{}")).not.toBe(base);
    expect(sign("secret", 1700000001, "nonce-1", "{}")).not.toBe(base);
    expect(sign("secret", 1700000000, "nonce-2", "{}")).not.toBe(base);
    expect(sign("secret", 1700000000, "nonce-1", "{ }")).not.toBe(base);
  });

  it("cannot be confused by shifting a field boundary", () => {
    // Without a separator, (ts=1, nonce="23") and (ts=12, nonce="3") sign
    // identical bytes.
    expect(sign("s", 1, "23", "body")).not.toBe(sign("s", 12, "3", "body"));
  });

  it("floors a fractional timestamp, matching the Luau side's math.floor", () => {
    expect(sign("s", 1000.9, "abc", "{}")).toBe(sign("s", 1000, "abc", "{}"));
  });
});

describe("verify", () => {
  it("accepts a matching pair and rejects a mismatch", () => {
    const sig = sign("secret", 1700000000, "n", "body");
    expect(verify(sig, sig)).toBe(true);
    expect(verify(sig, sign("secret", 1700000000, "n", "different body"))).toBe(false);
  });

  it("rejects rather than throws on a length mismatch", () => {
    // timingSafeEqual throws on unequal-length buffers; an attacker sending a
    // truncated signature must get `false`, not an unhandled exception that
    // could crash the request handler or leak a stack trace.
    expect(() => verify("abcd", "ab")).not.toThrow();
    expect(verify("abcd", "ab")).toBe(false);
    expect(verify("", "")).toBe(true);
  });

  it("rejects non-hex garbage rather than throwing", () => {
    expect(() => verify("not-hex-at-all!!", sign("s", 1, "n", "b"))).not.toThrow();
  });
});
