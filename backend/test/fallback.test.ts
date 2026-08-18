import { describe, expect, it } from "vitest";
import { extractBalancedJson } from "../src/llm/fallback.js";

describe("extractBalancedJson", () => {
  it("parses clean, already-valid JSON", () => {
    expect(extractBalancedJson('{"a":1,"b":2}')).toEqual({ a: 1, b: 2 });
  });

  it("extracts from prose-wrapped JSON", () => {
    const text = 'Sure, here is the decision: {"intent":"escalate","threatTier":4} -- hope that helps!';
    expect(extractBalancedJson(text)).toEqual({ intent: "escalate", threatTier: 4 });
  });

  it("extracts through nested braces", () => {
    const text = 'prefix {"objective":{"id":"hold_terminal","params":{"durationS":45}}} suffix';
    expect(extractBalancedJson(text)).toEqual({
      objective: { id: "hold_terminal", params: { durationS: 45 } },
    });
  });

  it("extracts JSON inside a markdown code fence", () => {
    const text = '```json\n{"intent":"hold_steady","spawnMultiplier":1.0}\n```';
    expect(extractBalancedJson(text)).toEqual({ intent: "hold_steady", spawnMultiplier: 1.0 });
  });

  it("ignores brace-shaped characters inside string values", () => {
    const text = '{"bark":"Reroute two units {they will not notice}."}';
    expect(extractBalancedJson(text)).toEqual({ bark: "Reroute two units {they will not notice}." });
  });

  it("ignores an escaped quote that would otherwise end the string early", () => {
    const text = '{"bark":"She said \\"stay back\\" and meant it."}';
    expect(extractBalancedJson(text)).toEqual({ bark: 'She said "stay back" and meant it.' });
  });

  it("returns null when there is no opening brace at all", () => {
    expect(extractBalancedJson("I cannot comply with that request.")).toBeNull();
  });

  it("returns null for an unbalanced/truncated object", () => {
    expect(extractBalancedJson('{"intent":"escalate","threatTier":4')).toBeNull();
  });

  it("returns null when the extracted region is not valid JSON despite balanced braces", () => {
    expect(extractBalancedJson("{not: valid, json: here}")).toBeNull();
  });

  it("returns null for an empty string", () => {
    expect(extractBalancedJson("")).toBeNull();
  });

  it("extracts the first balanced object when multiple appear, per the documented fallback step", () => {
    const text = '{"first":true} and also {"second":true}';
    expect(extractBalancedJson(text)).toEqual({ first: true });
  });
});
