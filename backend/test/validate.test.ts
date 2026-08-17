import { describe, expect, it } from "vitest";
import { parseLine, validateEnvelope } from "../src/ingest/validate.js";

/**
 * Pure validation, no database. Mirrors how the Luau side tests
 * core/telemetry/Buffer separately from the Roblox adapter that calls it.
 */

function valid(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    v: 1,
    ts: 1700000000,
    runId: "42-abc",
    serverId: "job-1",
    placeId: 1234567890,
    pid: "a3f9",
    type: "combat.hit",
    seq: 7,
    p: { damage: 22 },
    ...overrides,
  };
}

describe("validateEnvelope", () => {
  it("accepts a well-formed envelope", () => {
    const result = validateEnvelope(valid());
    expect(result).not.toBeNull();
    expect(result?.type).toBe("combat.hit");
    expect(result?.seq).toBe(7);
    expect(result?.payload).toEqual({ damage: 22 });
  });

  it("accepts a missing pid as null", () => {
    const withoutPid = valid();
    delete withoutPid["pid"];
    expect(validateEnvelope(withoutPid)?.pid).toBeNull();
  });

  it("accepts an explicit null pid", () => {
    expect(validateEnvelope(valid({ pid: null }))?.pid).toBeNull();
  });

  it("rejects non-object input outright", () => {
    expect(validateEnvelope(null)).toBeNull();
    expect(validateEnvelope(undefined)).toBeNull();
    expect(validateEnvelope("a string")).toBeNull();
    expect(validateEnvelope(42)).toBeNull();
    expect(validateEnvelope([1, 2, 3])).toBeNull();
  });

  it("rejects each required field's absence individually", () => {
    for (const field of ["v", "ts", "runId", "serverId", "placeId", "type", "seq", "p"]) {
      const broken = valid();
      delete broken[field];
      expect(validateEnvelope(broken), `missing ${field} should be rejected`).toBeNull();
    }
  });

  it("rejects wrong types for every field", () => {
    expect(validateEnvelope(valid({ v: "1" }))).toBeNull();
    expect(validateEnvelope(valid({ ts: "1700000000" }))).toBeNull();
    expect(validateEnvelope(valid({ runId: 42 }))).toBeNull();
    expect(validateEnvelope(valid({ serverId: {} }))).toBeNull();
    expect(validateEnvelope(valid({ placeId: "1234" }))).toBeNull();
    expect(validateEnvelope(valid({ pid: 42 }))).toBeNull();
    expect(validateEnvelope(valid({ type: 7 }))).toBeNull();
    expect(validateEnvelope(valid({ seq: "7" }))).toBeNull();
    expect(validateEnvelope(valid({ p: "not an object" }))).toBeNull();
    expect(validateEnvelope(valid({ p: [1, 2, 3] }))).toBeNull();
    expect(validateEnvelope(valid({ p: null }))).toBeNull();
  });

  it("rejects non-finite and non-integer numbers", () => {
    expect(validateEnvelope(valid({ v: 1.5 }))).toBeNull();
    expect(validateEnvelope(valid({ v: 0 }))).toBeNull();
    expect(validateEnvelope(valid({ v: -1 }))).toBeNull();
    expect(validateEnvelope(valid({ ts: Number.NaN }))).toBeNull();
    expect(validateEnvelope(valid({ ts: Number.POSITIVE_INFINITY }))).toBeNull();
    expect(validateEnvelope(valid({ ts: 0 }))).toBeNull();
    expect(validateEnvelope(valid({ ts: -5 }))).toBeNull();
    expect(validateEnvelope(valid({ placeId: 1.5 }))).toBeNull();
    expect(validateEnvelope(valid({ placeId: -1 }))).toBeNull();
    expect(validateEnvelope(valid({ seq: 0 }))).toBeNull();
    expect(validateEnvelope(valid({ seq: -1 }))).toBeNull();
    expect(validateEnvelope(valid({ seq: 1.5 }))).toBeNull();
  });

  it("rejects an empty string id, and a string past the length cap", () => {
    expect(validateEnvelope(valid({ runId: "" }))).toBeNull();
    expect(validateEnvelope(valid({ serverId: "" }))).toBeNull();
    expect(validateEnvelope(valid({ type: "" }))).toBeNull();
    expect(validateEnvelope(valid({ runId: "x".repeat(201) }))).toBeNull();
    expect(validateEnvelope(valid({ type: "x".repeat(65) }))).toBeNull();
    // Right at the boundary must still pass.
    expect(validateEnvelope(valid({ runId: "x".repeat(200) }))).not.toBeNull();
    expect(validateEnvelope(valid({ type: "x".repeat(64) }))).not.toBeNull();
  });

  it("passes through an arbitrary payload shape unmodified", () => {
    const payload = { nested: { a: [1, 2, 3] }, flag: true, note: "hi" };
    expect(validateEnvelope(valid({ p: payload }))?.payload).toEqual(payload);
  });

  it("accepts an empty payload object", () => {
    expect(validateEnvelope(valid({ p: {} }))).not.toBeNull();
  });

  it("ignores unknown top-level fields rather than rejecting on them", () => {
    // Forward compatibility: a future envelope version may add fields, and a
    // strict backend would reject every event from a newer game server.
    expect(validateEnvelope(valid({ future: "field" }))).not.toBeNull();
  });
});

describe("parseLine", () => {
  it("parses and validates a JSON line", () => {
    const result = parseLine(JSON.stringify(valid()));
    expect(result?.type).toBe("combat.hit");
  });

  it("returns null for invalid JSON rather than throwing", () => {
    expect(() => parseLine("{not json")).not.toThrow();
    expect(parseLine("{not json")).toBeNull();
    expect(parseLine("")).toBeNull();
    expect(parseLine("null")).toBeNull();
    expect(parseLine("[1,2,3]")).toBeNull();
  });
});
