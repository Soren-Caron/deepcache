/**
 * M5-10. Nightly recommender worker.
 *
 * Builds the item-item co-occurrence matrix `core/discovery/Recommend.luau`
 * scores against, from real telemetry: `loot.pickup` (which items a player
 * used in a run) joined against whether that run ended in `extract.success`
 * for that player (docs/06's "successful runs count double").
 *
 * `loadout_pairs(item_a, item_b, cooccur)` stores the full matrix
 * symmetrically -- both (a,b) and (b,a) -- so a query for "everything
 * co-occurring with item X" is a single indexed lookup on item_a, not a
 * UNION of two conditions. Per-item total counts live on the diagonal
 * (item_a = item_b = itemId), a standard trick that avoids a second table
 * for the cosine denominator.
 */

import type pg from "pg";

interface PickupRow {
  run_id: string;
  pid: string;
  item_id: string;
}

const SUCCESS_WEIGHT = 2;
const NORMAL_WEIGHT = 1;

/** Distinct (run, player, item) usages -- repeated pickups of the same item
 * in one run count once, matching "timesEquipped" as a presence signal, not
 * a raw pickup count. */
async function fetchDistinctUsages(pool: pg.Pool): Promise<PickupRow[]> {
  const result = await pool.query<PickupRow>(`
    SELECT DISTINCT run_id, pid, payload->>'itemId' AS item_id
    FROM events
    WHERE type = 'loot.pickup' AND pid IS NOT NULL AND payload->>'itemId' IS NOT NULL
  `);
  return result.rows;
}

/** (run_id, pid) pairs that ended in a successful extraction. */
async function fetchSuccessfulRunPlayers(pool: pg.Pool): Promise<Set<string>> {
  const result = await pool.query<{ run_id: string; pid: string }>(`
    SELECT DISTINCT run_id, pid FROM events
    WHERE type = 'extract.success' AND pid IS NOT NULL
  `);
  return new Set(result.rows.map((row) => `${row.run_id}:${row.pid}`));
}

export interface RecomputeResult {
  readonly pairs: number;
  readonly items: number;
  readonly usageRows: number;
}

export async function recomputeLoadoutPairs(pool: pg.Pool): Promise<RecomputeResult> {
  const usages = await fetchDistinctUsages(pool);
  const successfulRunPlayers = await fetchSuccessfulRunPlayers(pool);

  // Group usages by (run_id, pid) so co-occurrence is computed within one
  // player's one run, never across different players or different runs.
  const byRunPlayer = new Map<string, { weight: number; items: Set<string> }>();
  for (const row of usages) {
    const key = `${row.run_id}:${row.pid}`;
    const weight = successfulRunPlayers.has(key) ? SUCCESS_WEIGHT : NORMAL_WEIGHT;
    let group = byRunPlayer.get(key);
    if (group === undefined) {
      group = { weight, items: new Set() };
      byRunPlayer.set(key, group);
    }
    group.items.add(row.item_id);
  }

  const cooccur = new Map<string, number>();
  const addWeight = (a: string, b: string, weight: number): void => {
    const key = `${a} ${b}`;
    cooccur.set(key, (cooccur.get(key) ?? 0) + weight);
  };

  for (const { weight, items } of byRunPlayer.values()) {
    const itemList = [...items];
    // Diagonal: this player's use of this item in this run contributes to
    // the item's own total count.
    for (const item of itemList) {
      addWeight(item, item, weight);
    }
    // Off-diagonal, both directions, for every distinct pair used together.
    for (let i = 0; i < itemList.length; i += 1) {
      for (let j = i + 1; j < itemList.length; j += 1) {
        const a = itemList[i]!;
        const b = itemList[j]!;
        addWeight(a, b, weight);
        addWeight(b, a, weight);
      }
    }
  }

  const itemIds = new Set<string>();
  const rows: Array<[string, string, number]> = [];
  for (const [key, weight] of cooccur) {
    const [itemA, itemB] = key.split(" ") as [string, string];
    itemIds.add(itemA);
    itemIds.add(itemB);
    rows.push([itemA, itemB, Math.round(weight)]);
  }

  // Batched, not one INSERT per pair: a real dataset's item space is small
  // (~40 items per docs/06) but the number of distinct (run, player) groups
  // is not, and one round trip per pair would not scale with it.
  const BATCH_SIZE = 500;
  await pool.query("BEGIN");
  try {
    await pool.query("TRUNCATE loadout_pairs");
    for (let start = 0; start < rows.length; start += BATCH_SIZE) {
      const batch = rows.slice(start, start + BATCH_SIZE);
      const placeholders: string[] = [];
      const params: Array<string | number> = [];
      batch.forEach((row, i) => {
        const base = i * 3;
        placeholders.push(`($${base + 1}, $${base + 2}, $${base + 3})`);
        params.push(...row);
      });
      await pool.query(
        `INSERT INTO loadout_pairs (item_a, item_b, cooccur) VALUES ${placeholders.join(", ")}
         ON CONFLICT (item_a, item_b) DO UPDATE SET cooccur = EXCLUDED.cooccur`,
        params,
      );
    }
    await pool.query("COMMIT");
    return { pairs: cooccur.size, items: itemIds.size, usageRows: usages.length };
  } catch (err) {
    await pool.query("ROLLBACK");
    throw err;
  }
}

/** setInterval wrapper, exported separately so it never starts inside tests. */
export function startRecommendWorker(pool: pg.Pool, intervalMs = 24 * 60 * 60 * 1000): NodeJS.Timeout {
  return setInterval(() => {
    recomputeLoadoutPairs(pool).catch((err: unknown) => {
      console.error("recompute loadout_pairs failed", err);
    });
  }, intervalMs);
}
