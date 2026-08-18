/**
 * M5-8. Poisson-arrival matchmaking simulation.
 *
 * A portfolio project has no concurrent players to measure a real queue
 * against. This simulates arrivals (a Poisson process, configurable rate),
 * synthetic ratings, and the exact bucketing/widening schedule docs/06
 * specifies -- separately implemented here in TypeScript (not requiring
 * core/discovery/Bucket.luau, which sim/ cannot import) but to the same
 * documented thresholds, so a drift between the two would need to be
 * caught by comparing behavior, not assumed away by sharing code.
 */

import { Rng } from "./rng.js";

export const BUCKET_WIDTH = 100;
export const RADIUS1_AT_SECONDS = 15;
export const RADIUS2_AT_SECONDS = 30;
export const ANY_AT_SECONDS = 45;
export const UNDERSIZED_AT_SECONDS = 75;

export type WideningStage = "own" | "radius1" | "radius2" | "any" | "undersized";

export function bucketFor(rating: number): number {
  return Math.floor(rating / BUCKET_WIDTH);
}

export function stageFor(waitedSeconds: number): WideningStage {
  if (waitedSeconds >= UNDERSIZED_AT_SECONDS) return "undersized";
  if (waitedSeconds >= ANY_AT_SECONDS) return "any";
  if (waitedSeconds >= RADIUS2_AT_SECONDS) return "radius2";
  if (waitedSeconds >= RADIUS1_AT_SECONDS) return "radius1";
  return "own";
}

function inSearchRange(ownBucket: number, candidateBucket: number, stage: WideningStage): boolean {
  if (stage === "own") return candidateBucket === ownBucket;
  if (stage === "radius1") return Math.abs(candidateBucket - ownBucket) <= 1;
  if (stage === "radius2") return Math.abs(candidateBucket - ownBucket) <= 2;
  return true; // "any" and "undersized" both search everyone
}

export interface QueuedPlayer {
  readonly id: number;
  readonly rating: number;
  readonly arrivalTime: number;
}

export interface MatchOutcome {
  readonly waitSeconds: number;
  readonly squadSize: number;
  readonly ratingSpread: number;
  readonly undersized: boolean;
}

export interface SimConfig {
  readonly arrivalRatePerSecond: number;
  readonly durationSeconds: number;
  readonly targetSquadSize: number;
  readonly ratingMean: number;
  readonly ratingStdDev: number;
  readonly seed: number;
}

const MIN_RATING = 100;
const MAX_RATING = 3000;

function clampRating(rating: number): number {
  return Math.max(MIN_RATING, Math.min(MAX_RATING, rating));
}

/**
 * Tries to resolve the single oldest queued player against everyone else
 * currently waiting. Returns true (and mutates `queue`/`outcomes`) if a
 * squad was formed, false if the oldest player must keep waiting.
 *
 * Oldest-first isn't cosmetic: it is what makes "start undersized at 75s"
 * apply to the player who has actually waited 75s, not to whichever
 * arrival happens to trigger a re-check.
 */
function tryMatchOldest(
  queue: QueuedPlayer[],
  now: number,
  config: SimConfig,
  outcomes: MatchOutcome[],
): boolean {
  const oldest = queue[0];
  if (oldest === undefined) return false;

  const waited = now - oldest.arrivalTime;
  const stage = stageFor(waited);
  const ownBucket = bucketFor(oldest.rating);

  const candidateIndices: number[] = [];
  for (let i = 1; i < queue.length; i += 1) {
    const candidate = queue[i];
    if (candidate && inSearchRange(ownBucket, bucketFor(candidate.rating), stage)) {
      candidateIndices.push(i);
    }
  }
  // docs/06: "any bucket, fill by closest rating."
  candidateIndices.sort(
    (a, b) => Math.abs(queue[a]!.rating - oldest.rating) - Math.abs(queue[b]!.rating - oldest.rating),
  );

  const wantMore = config.targetSquadSize - 1;
  const hasFullSquad = candidateIndices.length >= wantMore;
  const mustLaunchUndersized = stage === "undersized";

  if (!hasFullSquad && !mustLaunchUndersized) {
    return false;
  }

  const takeCount = Math.min(wantMore, candidateIndices.length);
  const squadIndices = [0, ...candidateIndices.slice(0, takeCount)];
  const ratings = squadIndices.map((i) => queue[i]!.rating);

  outcomes.push({
    waitSeconds: waited,
    squadSize: squadIndices.length,
    ratingSpread: Math.max(...ratings) - Math.min(...ratings),
    undersized: squadIndices.length < config.targetSquadSize,
  });

  for (const i of [...squadIndices].sort((a, b) => b - a)) {
    queue.splice(i, 1);
  }
  return true;
}

/**
 * Runs one full simulation and returns every match/undersized-launch
 * outcome.
 *
 * Interleaves two event types in chronological order: arrivals (Poisson)
 * and a periodic 1-second queue re-check. The re-check matters more than
 * it looks: without it, a player queued near the end of a sparse window
 * (low lambda) with no further arrivals before the simulation ends would
 * never get re-evaluated at all, and so could never trigger the 75s
 * undersized-launch rule -- found by running this at population=5 and
 * seeing zero undersized launches, which is the opposite of what a
 * near-empty queue should produce.
 */
export function simulate(config: SimConfig): MatchOutcome[] {
  const rng = new Rng(config.seed);
  const outcomes: MatchOutcome[] = [];
  const queue: QueuedPlayer[] = [];
  let nextId = 0;

  let nextArrival = rng.nextExponential(config.arrivalRatePerSecond);
  let nextTick = 1;

  while (nextArrival < config.durationSeconds || nextTick < config.durationSeconds) {
    const isArrival = nextArrival <= nextTick;
    const t = isArrival ? nextArrival : nextTick;
    if (t >= config.durationSeconds) break;

    if (isArrival) {
      queue.push({
        id: nextId,
        rating: clampRating(config.ratingMean + rng.nextGaussian() * config.ratingStdDev),
        arrivalTime: t,
      });
      nextId += 1;
      nextArrival = t + rng.nextExponential(config.arrivalRatePerSecond);
    } else {
      nextTick = t + 1;
    }

    let progressed = true;
    while (progressed && queue.length > 0) {
      progressed = tryMatchOldest(queue, t, config, outcomes);
    }
  }

  return outcomes;
}

export function percentile(sortedValues: number[], fraction: number): number {
  if (sortedValues.length === 0) return 0;
  const index = Math.min(sortedValues.length - 1, Math.ceil(sortedValues.length * fraction) - 1);
  return sortedValues[Math.max(0, index)]!;
}

export interface SimReport {
  readonly config: SimConfig;
  readonly matched: number;
  readonly p50WaitSeconds: number;
  readonly p95WaitSeconds: number;
  readonly p99WaitSeconds: number;
  readonly meanRatingSpread: number;
  readonly undersizedRate: number;
}

export function summarize(config: SimConfig, outcomes: MatchOutcome[]): SimReport {
  const waits = outcomes.map((o) => o.waitSeconds).sort((a, b) => a - b);
  const spreads = outcomes.map((o) => o.ratingSpread);
  const undersizedCount = outcomes.filter((o) => o.undersized).length;

  return {
    config,
    matched: outcomes.length,
    p50WaitSeconds: percentile(waits, 0.5),
    p95WaitSeconds: percentile(waits, 0.95),
    p99WaitSeconds: percentile(waits, 0.99),
    meanRatingSpread: spreads.length > 0 ? spreads.reduce((a, b) => a + b, 0) / spreads.length : 0,
    undersizedRate: outcomes.length > 0 ? undersizedCount / outcomes.length : 0,
  };
}
