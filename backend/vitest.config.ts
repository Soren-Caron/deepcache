import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: ["./test/global-setup.ts"],

    // Every suite here runs against ONE real local Postgres, on purpose --
    // see ingest.test.ts's rationale for why a mock would prove nothing. The
    // consequence is that parallel test files are not independent: they
    // contend for the same connections, locks, and disk, and they can see
    // each other's rows.
    //
    // Both failure modes showed up for real while building M6-7:
    //   - `economy.test.ts` counted runs from `run_summary` that a different
    //     file had inserted, silently pushing a "sample too small" case over
    //     the threshold so it passed for the wrong reason.
    //   - `reconcile.test.ts`'s 2,000-run fuzz saturated Postgres hard enough
    //     that ingest.test.ts's 10,000-line performance assertion measured
    //     590ms against its 500ms budget -- while measuring 396-419ms when
    //     run alone.
    //
    // That second one is the reason for this setting rather than just tidier
    // fixtures. docs/04's criterion is a claim about the *server*; measuring
    // it while another suite hammers the same database is measuring something
    // else and calling it that claim. A performance assertion whose result
    // depends on what else happens to be running is worse than no assertion,
    // because it teaches you to ignore a red suite.
    //
    // Cost is a few seconds of wall time on a suite that runs in ~10s. Worth
    // it for a DB-backed suite that is supposed to be believable.
    fileParallelism: false,
  },
});
