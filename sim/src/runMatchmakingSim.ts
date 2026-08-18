/**
 * M5-8. `npm --prefix sim run matchmaking`
 *
 * Two things reported, matching tasks/BACKLOG.md's accept criterion
 * literally: (1) a population sweep 5-500 for a general shape of the
 * curve, (2) a dedicated run at exactly lambda=1/s, the specific rate the
 * accept criterion names, checked against p95 < 30s.
 *
 * "Population" here means expected arrivals over a fixed 600s (10-minute)
 * observation window -- lambda = population / 600 -- not concurrent
 * players directly, since concurrency depends on session length, which
 * this simulation doesn't model (it only models queue wait, not the run
 * itself). Documented rather than left implicit, since "population" is
 * doing real interpretive work here.
 */

import { simulate, summarize, type SimConfig } from "./matchmaking.js";

const WINDOW_SECONDS = 600;
const POPULATIONS = [5, 10, 25, 50, 100, 250, 500];
const TARGET_SQUAD_SIZE = 3; // docs/01: squad size 1-4, tuned for 3
const RATING_MEAN = 1500;
const RATING_STDDEV = 250;
const SEED = 1;

function runOne(config: SimConfig) {
  const outcomes = simulate(config);
  return summarize(config, outcomes);
}

function fmt(n: number, digits = 1): string {
  return n.toFixed(digits);
}

function main() {
  console.log(`Population sweep -- ${WINDOW_SECONDS}s window, squad size ${TARGET_SQUAD_SIZE}, seed ${SEED}`);
  console.log(
    "population".padEnd(11) +
      "lambda/s".padEnd(10) +
      "matched".padEnd(9) +
      "p50 wait".padEnd(10) +
      "p95 wait".padEnd(10) +
      "p99 wait".padEnd(10) +
      "spread".padEnd(9) +
      "undersized",
  );
  for (const population of POPULATIONS) {
    const arrivalRatePerSecond = population / WINDOW_SECONDS;
    const report = runOne({
      arrivalRatePerSecond,
      durationSeconds: WINDOW_SECONDS,
      targetSquadSize: TARGET_SQUAD_SIZE,
      ratingMean: RATING_MEAN,
      ratingStdDev: RATING_STDDEV,
      seed: SEED,
    });
    console.log(
      String(population).padEnd(11) +
        fmt(arrivalRatePerSecond, 3).padEnd(10) +
        String(report.matched).padEnd(9) +
        `${fmt(report.p50WaitSeconds)}s`.padEnd(10) +
        `${fmt(report.p95WaitSeconds)}s`.padEnd(10) +
        `${fmt(report.p99WaitSeconds)}s`.padEnd(10) +
        fmt(report.meanRatingSpread).padEnd(9) +
        `${fmt(report.undersizedRate * 100, 1)}%`,
    );
  }

  console.log("");
  console.log("Accept criterion check -- lambda=1/s, 600s window:");
  const acceptReport = runOne({
    arrivalRatePerSecond: 1,
    durationSeconds: WINDOW_SECONDS,
    targetSquadSize: TARGET_SQUAD_SIZE,
    ratingMean: RATING_MEAN,
    ratingStdDev: RATING_STDDEV,
    seed: SEED,
  });
  console.log(
    `matched=${acceptReport.matched} p50=${fmt(acceptReport.p50WaitSeconds)}s ` +
      `p95=${fmt(acceptReport.p95WaitSeconds)}s p99=${fmt(acceptReport.p99WaitSeconds)}s ` +
      `meanSpread=${fmt(acceptReport.meanRatingSpread)} undersized=${fmt(acceptReport.undersizedRate * 100, 1)}%`,
  );
  const pass = acceptReport.p95WaitSeconds < 30;
  console.log(pass ? "PASS: p95 < 30s" : "FAIL: p95 >= 30s");
  if (!pass) {
    process.exitCode = 1;
  }
}

main();
