/**
 * M5-11. Offline evaluation: recall@3 against a popularity baseline.
 * `npm run eval:recommend`. See docs/06 §Offline evaluation.
 *
 * 1. Split runs by time -- the last 20% (by each run's earliest event) is
 *    held out.
 * 2. For each held-out (run, pid), hide their actual items; generate
 *    top-3 from TRAINING DATA ONLY (the held-out run itself never leaks
 *    into the co-occurrence matrix or the player's "owned" history).
 * 3. recall@3 = fraction of held-out cases where at least one actually-
 *    used item appears in the predicted top 3.
 * 4. Compare against the training-only popularity baseline applied
 *    uniformly.
 *
 * Success is not assumed -- this prints and records whatever the real
 * numbers say, including a tie or a loss against the baseline, per
 * tasks/BACKLOG.md M5-11's explicit "whatever it says."
 */

import { getPool } from "./db.js";
import { loadConfig } from "./config.js";
import { popularityBaseline, recommend } from "./discovery/recommend.js";

const HOLDOUT_FRACTION = 0.2;
const SUCCESS_WEIGHT = 2;
const NORMAL_WEIGHT = 1;
const TOP_N = 3;

interface UsageRow {
  run_id: string;
  pid: string;
  item_id: string;
  run_ts: string;
}

async function main(): Promise<void> {
  const pool = getPool(loadConfig());

  const usageResult = await pool.query<UsageRow>(`
    SELECT DISTINCT p.run_id, p.pid, p.payload->>'itemId' AS item_id, r.run_ts
    FROM events p
    JOIN (SELECT run_id, min(ts) AS run_ts FROM events GROUP BY run_id) r
      ON r.run_id = p.run_id
    WHERE p.type = 'loot.pickup' AND p.pid IS NOT NULL AND p.payload->>'itemId' IS NOT NULL
    ORDER BY r.run_ts
  `);
  const usages = usageResult.rows;

  const successResult = await pool.query<{ run_id: string; pid: string }>(`
    SELECT DISTINCT run_id, pid FROM events WHERE type = 'extract.success' AND pid IS NOT NULL
  `);
  const successfulRunPlayers = new Set(successResult.rows.map((r) => `${r.run_id}:${r.pid}`));

  // Chronological run order, deduplicated, to find the 80/20 split point.
  const runOrder: string[] = [];
  const seenRuns = new Set<string>();
  for (const row of usages) {
    if (!seenRuns.has(row.run_id)) {
      seenRuns.add(row.run_id);
      runOrder.push(row.run_id);
    }
  }
  const splitIndex = Math.floor(runOrder.length * (1 - HOLDOUT_FRACTION));
  const trainingRuns = new Set(runOrder.slice(0, splitIndex));
  const holdoutRuns = new Set(runOrder.slice(splitIndex));

  if (holdoutRuns.size === 0 || trainingRuns.size === 0) {
    console.log(`Not enough distinct runs to evaluate (${runOrder.length} total). Nothing to report.`);
    await pool.end();
    return;
  }

  // Training-only co-occurrence + counts + per-pid owned-item history.
  const trainingByRunPlayer = new Map<string, { weight: number; items: Set<string> }>();
  const ownedByPid = new Map<string, Set<string>>();
  const trainingRunsByPid = new Map<string, Set<string>>();

  for (const row of usages) {
    if (!trainingRuns.has(row.run_id)) continue;
    const key = `${row.run_id}:${row.pid}`;
    const weight = successfulRunPlayers.has(key) ? SUCCESS_WEIGHT : NORMAL_WEIGHT;
    let group = trainingByRunPlayer.get(key);
    if (group === undefined) {
      group = { weight, items: new Set() };
      trainingByRunPlayer.set(key, group);
    }
    group.items.add(row.item_id);

    let owned = ownedByPid.get(row.pid);
    if (owned === undefined) {
      owned = new Set();
      ownedByPid.set(row.pid, owned);
    }
    owned.add(row.item_id);

    let runsForPid = trainingRunsByPid.get(row.pid);
    if (runsForPid === undefined) {
      runsForPid = new Set();
      trainingRunsByPid.set(row.pid, runsForPid);
    }
    runsForPid.add(row.run_id);
  }

  const cooccur = new Map<string, Map<string, number>>();
  const counts = new Map<string, number>();
  const addWeight = (a: string, b: string, weight: number): void => {
    if (a === b) {
      counts.set(a, (counts.get(a) ?? 0) + weight);
      return;
    }
    let row = cooccur.get(a);
    if (row === undefined) {
      row = new Map();
      cooccur.set(a, row);
    }
    row.set(b, (row.get(b) ?? 0) + weight);
  };
  for (const { weight, items } of trainingByRunPlayer.values()) {
    const list = [...items];
    for (const item of list) addWeight(item, item, weight);
    for (let i = 0; i < list.length; i += 1) {
      for (let j = i + 1; j < list.length; j += 1) {
        addWeight(list[i]!, list[j]!, weight);
        addWeight(list[j]!, list[i]!, weight);
      }
    }
  }
  const allItemIds = [...counts.keys()];

  // Held-out actual usage per (run, pid).
  const holdoutByRunPlayer = new Map<string, Set<string>>();
  for (const row of usages) {
    if (!holdoutRuns.has(row.run_id)) continue;
    const key = `${row.run_id}:${row.pid}`;
    let items = holdoutByRunPlayer.get(key);
    if (items === undefined) {
      items = new Set();
      holdoutByRunPlayer.set(key, items);
    }
    items.add(row.item_id);
  }

  let personalizedHits = 0;
  let baselineHits = 0;
  let evaluated = 0;
  let coldStartCount = 0;

  const globalBaseline = popularityBaseline(allItemIds, counts, [], TOP_N).map((r) => r.itemId);

  for (const [key, actualItems] of holdoutByRunPlayer) {
    const pid = key.split(":")[1]!;
    const owned = [...(ownedByPid.get(pid) ?? new Set<string>())];
    const runsPlayed = trainingRunsByPid.get(pid)?.size ?? 0;

    const result = recommend(runsPlayed, owned, allItemIds, cooccur, counts, TOP_N);
    if (result.fallback) coldStartCount += 1;
    evaluated += 1;

    const predictedIds = new Set(result.recommendations.map((r) => r.itemId));
    if ([...actualItems].some((item) => predictedIds.has(item))) {
      personalizedHits += 1;
    }
    if ([...actualItems].some((item) => globalBaseline.includes(item))) {
      baselineHits += 1;
    }
  }

  const recallPersonalized = evaluated > 0 ? personalizedHits / evaluated : 0;
  const recallBaseline = evaluated > 0 ? baselineHits / evaluated : 0;

  console.log(`Runs: ${runOrder.length} total, ${trainingRuns.size} training, ${holdoutRuns.size} held out.`);
  console.log(`Held-out (run, pid) evaluations: ${evaluated} (${coldStartCount} cold-start).`);
  console.log("");
  console.log("method".padEnd(20) + "recall@3".padEnd(12) + "hits/total");
  console.log(
    "personalized".padEnd(20) +
      `${(recallPersonalized * 100).toFixed(1)}%`.padEnd(12) +
      `${personalizedHits}/${evaluated}`,
  );
  console.log(
    "popularity baseline".padEnd(20) +
      `${(recallBaseline * 100).toFixed(1)}%`.padEnd(12) +
      `${baselineHits}/${evaluated}`,
  );
  console.log("");
  if (recallPersonalized > recallBaseline) {
    console.log(
      `Personalized beats the popularity baseline by ${((recallPersonalized - recallBaseline) * 100).toFixed(1)} points.`,
    );
  } else if (recallPersonalized < recallBaseline) {
    console.log(
      `Personalized LOSES to the popularity baseline by ${((recallBaseline - recallPersonalized) * 100).toFixed(1)} points.`,
    );
  } else {
    console.log("Personalized ties the popularity baseline exactly.");
  }

  await pool.end();
}

main().catch((err: unknown) => {
  console.error("eval:recommend failed:", err);
  process.exitCode = 1;
});
