import { describe, expect, it } from "vitest";
import { popularityBaseline, recommend, similarity, topN } from "../src/discovery/recommend.js";

/**
 * M5-10. Mirrors tests/recommend.spec.luau's hand-computed cases exactly --
 * both language implementations are checked against the same numbers, not
 * against each other, so a shared bug wouldn't hide behind agreement.
 */

describe("recommend.ts sync with core/discovery/Recommend.luau", () => {
  it("shrinkage suppresses a 2-count pair -- same case as the Luau suite", () => {
    const score = similarity(2, 2, 2);
    expect(score).toBeCloseTo(1 / 6, 9);
    expect(score).not.toBeCloseTo(1.0, 2);
  });

  it("a well-supported pair, hand-computed identically to the Luau suite", () => {
    const score = similarity(50, 100, 80);
    expect(score).toBeCloseTo(0.465847, 4);
  });

  it("topN ranking matches the Luau suite's hand-computed fixture", () => {
    const cooccur = new Map([
      ["itemA", new Map([["owned", 15]])],
      ["itemB", new Map([["owned", 8]])],
      ["owned", new Map([["itemA", 15], ["itemB", 8]])],
    ]);
    const counts = new Map([["owned", 30], ["itemA", 20], ["itemB", 10]]);
    const recs = topN(["itemA", "itemB", "owned"], ["owned"], cooccur, counts, 5);
    expect(recs).toHaveLength(2);
    expect(recs[0]?.itemId).toBe("itemA");
    expect(recs[0]?.score).toBeCloseTo(0.36742, 4);
    expect(recs[1]?.itemId).toBe("itemB");
    expect(recs[1]?.score).toBeCloseTo(0.20528, 4);
  });

  it("popularityBaseline excludes owned items", () => {
    const counts = new Map([["owned", 20], ["itemA", 20], ["itemB", 5]]);
    const recs = popularityBaseline(["itemA", "itemB", "owned"], counts, ["owned"], 5);
    expect(recs.every((r) => r.itemId !== "owned")).toBe(true);
    expect(recs[0]?.itemId).toBe("itemA");
  });

  it("cold start (< 3 runs) returns the popularity baseline with fallback=true", () => {
    const counts = new Map([["itemA", 30], ["itemB", 20], ["itemC", 5]]);
    const result = recommend(0, [], ["itemA", "itemB", "itemC"], new Map(), counts, 3);
    expect(result.fallback).toBe(true);
    expect(result.recommendations[0]?.itemId).toBe("itemA");
  });

  it("3+ runs returns personalized scoring with fallback=false", () => {
    const cooccur = new Map([["itemA", new Map([["itemB", 15]])]]);
    const counts = new Map([["itemA", 30], ["itemB", 20], ["itemC", 5]]);
    const result = recommend(3, ["itemA"], ["itemA", "itemB", "itemC"], cooccur, counts, 3);
    expect(result.fallback).toBe(false);
    expect(result.recommendations.some((r) => r.itemId === "itemA")).toBe(false);
  });
});
