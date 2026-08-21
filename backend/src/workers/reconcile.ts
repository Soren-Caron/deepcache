/**
 * M6-7. Nightly ledger reconciliation.
 *
 * docs/07 §Persistence: the ledger in Postgres is authoritative, and
 * `DataService` keeps a per-player cached balance in DataStore so the game
 * never blocks a payout on a network round trip. Two stores holding the same
 * number will eventually disagree; this is the job that finds out.
 *
 * It recomputes each player's balance as `SUM(delta)` over the ledger and
 * compares it to the cached value the game last reported. **Target: zero
 * mismatches.** docs/07 is explicit that a nonzero count is a bug report and
 * not a tuning knob, so nothing here "corrects" a drifting balance -- a job
 * that silently rewrites balances to match whichever side it trusts destroys
 * the evidence needed to find out why they diverged, and would happily
 * launder a duping exploit into a legitimate-looking balance.
 *
 * `balance_after` is also checked, independently of the cache. Every ledger
 * row carries the running balance at the moment it was written, so the
 * sequence must satisfy `balance_after[n] = balance_after[n-1] + delta[n]`.
 * That catches corruption *inside* the authoritative store, which comparing
 * against the cache cannot: if the ledger itself is wrong, a cache that
 * agrees with it is also wrong and the comparison passes.
 */

import type pg from "pg";

export type MismatchKind = "cache_drift" | "running_balance_broken";

export interface Mismatch {
  readonly pid: string;
  readonly kind: MismatchKind;
  /** Authoritative value recomputed from the ledger. */
  readonly expected: number;
  /** What the other side claimed. */
  readonly actual: number;
  readonly delta: number;
  /** The run the discrepancy most likely came from, when identifiable. */
  readonly likelyRunId: string | null;
}

export interface ReconcileReport {
  readonly playersChecked: number;
  readonly entriesChecked: number;
  readonly mismatches: Mismatch[];
}

interface SumRow {
  pid: string;
  ledger_balance: string;
  entries: string;
}

interface CacheRow {
  pid: string;
  cached_balance: string;
}

/**
 * Walk each player's entries in write order and verify the running balance
 * column is self-consistent. Returns the first break per player: once the
 * chain is broken every subsequent row is off by the same amount, so
 * reporting all of them is noise that buries the row that actually matters.
 */
async function checkRunningBalances(pool: pg.Pool): Promise<Mismatch[]> {
  const rows = await pool.query<{
    pid: string;
    delta: string;
    balance_after: string;
    run_id: string | null;
  }>(
    `SELECT pid, delta, balance_after, run_id
     FROM ledger ORDER BY pid, id`,
  );

  const mismatches: Mismatch[] = [];
  let currentPid: string | null = null;
  let running = 0;
  let broken = false;

  for (const row of rows.rows) {
    if (row.pid !== currentPid) {
      currentPid = row.pid;
      running = 0;
      broken = false;
    }
    if (broken) continue;

    running += Number(row.delta);
    const claimed = Number(row.balance_after);
    if (claimed !== running) {
      mismatches.push({
        pid: row.pid,
        kind: "running_balance_broken",
        expected: running,
        actual: claimed,
        delta: claimed - running,
        likelyRunId: row.run_id,
      });
      broken = true;
    }
  }
  return mismatches;
}

/**
 * Compare the ledger sum against the game's cached balance.
 *
 * A player with ledger entries but no cache row is *not* a mismatch: the
 * cache is written behind (M6-2's queue coalesces at one write per player
 * per 6s), so a player whose first payout landed seconds ago legitimately has
 * no cached row yet. Treating that as drift would make the target of zero
 * mismatches unreachable by design.
 */
async function checkCacheDrift(pool: pg.Pool): Promise<{
  mismatches: Mismatch[];
  playersChecked: number;
  entriesChecked: number;
}> {
  const sums = await pool.query<SumRow>(
    `SELECT pid, SUM(delta) AS ledger_balance, COUNT(*) AS entries
     FROM ledger GROUP BY pid`,
  );
  const caches = await pool.query<CacheRow>(
    `SELECT pid, cached_balance FROM balance_cache`,
  );

  const cacheByPid = new Map<string, number>();
  for (const row of caches.rows) {
    cacheByPid.set(row.pid, Number(row.cached_balance));
  }

  const mismatches: Mismatch[] = [];
  let entriesChecked = 0;

  for (const row of sums.rows) {
    const expected = Number(row.ledger_balance);
    entriesChecked += Number(row.entries);
    const cached = cacheByPid.get(row.pid);
    if (cached === undefined) continue; // not yet written behind; see above
    if (cached !== expected) {
      // Narrow the blame to a run rather than just reporting a number: the
      // first thing anyone asks about a drift is "which run did this".
      const suspect = await pool.query<{ run_id: string | null }>(
        `SELECT run_id FROM ledger
         WHERE pid = $1 AND run_id IS NOT NULL
         ORDER BY id DESC LIMIT 1`,
        [row.pid],
      );
      mismatches.push({
        pid: row.pid,
        kind: "cache_drift",
        expected,
        actual: cached,
        delta: cached - expected,
        likelyRunId: suspect.rows[0]?.run_id ?? null,
      });
    }
  }

  return { mismatches, playersChecked: sums.rowCount ?? 0, entriesChecked };
}

export async function reconcile(pool: pg.Pool): Promise<ReconcileReport> {
  const cache = await checkCacheDrift(pool);
  const running = await checkRunningBalances(pool);
  return {
    playersChecked: cache.playersChecked,
    entriesChecked: cache.entriesChecked,
    mismatches: [...cache.mismatches, ...running],
  };
}

const DAY_MS = 24 * 60 * 60 * 1000;

export function startReconcileWorker(
  pool: pg.Pool,
  intervalMs = DAY_MS,
  onReport?: (report: ReconcileReport) => void,
): NodeJS.Timeout {
  return setInterval(() => {
    void reconcile(pool)
      .then((report) => onReport?.(report))
      .catch(() => {
        // Never take the process down; the next pass re-reads the same rows.
      });
  }, intervalMs);
}
