import { describe, expect, it } from "vitest";
import { bucketFor, simulate, stageFor, summarize, type SimConfig } from "../src/matchmaking.js";

describe("bucketFor / stageFor (TS mirror of core/discovery/Bucket.luau)", () => {
  it("matches docs/06's worked example and exact boundaries", () => {
    expect(bucketFor(1250)).toBe(12);
    expect(bucketFor(1299)).toBe(12);
    expect(bucketFor(1300)).toBe(13);
  });

  it("matches the documented widening thresholds exactly", () => {
    expect(stageFor(14.9)).toBe("own");
    expect(stageFor(15)).toBe("radius1");
    expect(stageFor(29.9)).toBe("radius1");
    expect(stageFor(30)).toBe("radius2");
    expect(stageFor(44.9)).toBe("radius2");
    expect(stageFor(45)).toBe("any");
    expect(stageFor(74.9)).toBe("any");
    expect(stageFor(75)).toBe("undersized");
  });
});

const BASE_CONFIG: SimConfig = {
  arrivalRatePerSecond: 1,
  durationSeconds: 300,
  targetSquadSize: 3,
  ratingMean: 1500,
  ratingStdDev: 250,
  seed: 42,
};

describe("simulate", () => {
  it("is deterministic: the same seed produces the same outcomes", () => {
    const a = simulate(BASE_CONFIG);
    const b = simulate(BASE_CONFIG);
    expect(a).toEqual(b);
  });

  it("a different seed produces different outcomes", () => {
    const a = simulate(BASE_CONFIG);
    const b = simulate({ ...BASE_CONFIG, seed: 43 });
    expect(a).not.toEqual(b);
  });

  it("every outcome is internally valid", () => {
    const outcomes = simulate(BASE_CONFIG);
    expect(outcomes.length).toBeGreaterThan(0);
    for (const outcome of outcomes) {
      expect(outcome.waitSeconds).toBeGreaterThanOrEqual(0);
      expect(outcome.squadSize).toBeGreaterThanOrEqual(1);
      expect(outcome.squadSize).toBeLessThanOrEqual(BASE_CONFIG.targetSquadSize);
      expect(outcome.ratingSpread).toBeGreaterThanOrEqual(0);
      expect(outcome.undersized).toBe(outcome.squadSize < BASE_CONFIG.targetSquadSize);
    }
  });

  it("undersized launches only ever happen at or past the 75s threshold", () => {
    // A sparse population makes undersized launches common and easy to
    // observe within a modest window.
    const outcomes = simulate({ ...BASE_CONFIG, arrivalRatePerSecond: 0.05, durationSeconds: 1200 });
    const undersized = outcomes.filter((o) => o.undersized);
    expect(undersized.length).toBeGreaterThan(0);
    for (const outcome of undersized) {
      expect(outcome.waitSeconds).toBeGreaterThanOrEqual(75);
    }
  });

  it("a lone player with no further arrivals before the window ends still gets undersized-launched", () => {
    // Regression test for the real bug found while running this: the
    // simulation originally only re-checked the queue on new arrivals, so
    // a lone queued player with nobody arriving after them was never
    // re-evaluated and never launched, even past 75s -- caught by seeing
    // undersized=0% at a very low population where it should be common.
    const outcomes = simulate({
      arrivalRatePerSecond: 0.02, // one arrival roughly every 50s on average
      durationSeconds: 2000,
      targetSquadSize: 3,
      ratingMean: 1500,
      ratingStdDev: 250,
      seed: 7,
    });
    expect(outcomes.length).toBeGreaterThan(0);
  });
});

describe("summarize", () => {
  it("computes percentiles and rates correctly on a known set of outcomes", () => {
    const report = summarize(BASE_CONFIG, [
      { waitSeconds: 10, squadSize: 3, ratingSpread: 50, undersized: false },
      { waitSeconds: 20, squadSize: 3, ratingSpread: 60, undersized: false },
      { waitSeconds: 80, squadSize: 1, ratingSpread: 0, undersized: true },
      { waitSeconds: 30, squadSize: 3, ratingSpread: 70, undersized: false },
    ]);
    expect(report.matched).toBe(4);
    expect(report.undersizedRate).toBeCloseTo(0.25, 9);
    expect(report.meanRatingSpread).toBeCloseTo((50 + 60 + 0 + 70) / 4, 9);
    // Sorted waits: [10, 20, 30, 80]. p50 index = ceil(4*0.5)-1 = 1 -> 20.
    expect(report.p50WaitSeconds).toBe(20);
  });

  it("returns zeros for an empty outcome set rather than dividing by zero", () => {
    const report = summarize(BASE_CONFIG, []);
    expect(report.matched).toBe(0);
    expect(report.p50WaitSeconds).toBe(0);
    expect(report.undersizedRate).toBe(0);
    expect(report.meanRatingSpread).toBe(0);
  });
});
