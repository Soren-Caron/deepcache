/**
 * M5-10. GET /v1/recommend/loadout?pid=<pid> -- docs/06 §Serving.
 *
 * Reads `loadout_pairs` (M5-10's own recompute worker output), the
 * player's run count from `player_stats` (cold-start gate), and their
 * owned items from `loot.pickup` telemetry directly.
 */

import type { FastifyInstance } from "fastify";
import { getPool } from "../db.js";
import { recommend, type Recommendation } from "../discovery/recommend.js";

export type RecommendReason = "pairs_with_owned" | "popular_at_your_rating";

export interface RecommendResponseItem {
  readonly itemId: string;
  readonly score: number;
  readonly reason: RecommendReason;
}

export interface RecommendResponse {
  readonly recommendations: RecommendResponseItem[];
  readonly fallback: boolean;
}

const DEFAULT_N = 3;

async function fetchLoadoutData(app: FastifyInstance, pid: string) {
  const pool = getPool(app.config);

  const pairRows = await pool.query<{ item_a: string; item_b: string; cooccur: number }>(
    "SELECT item_a, item_b, cooccur FROM loadout_pairs",
  );

  const cooccur = new Map<string, Map<string, number>>();
  const counts = new Map<string, number>();
  const allItemIds = new Set<string>();
  for (const row of pairRows.rows) {
    allItemIds.add(row.item_a);
    allItemIds.add(row.item_b);
    if (row.item_a === row.item_b) {
      counts.set(row.item_a, row.cooccur);
    } else {
      let inner = cooccur.get(row.item_a);
      if (inner === undefined) {
        inner = new Map();
        cooccur.set(row.item_a, inner);
      }
      inner.set(row.item_b, row.cooccur);
    }
  }

  const ownedRows = await pool.query<{ item_id: string }>(
    "SELECT DISTINCT payload->>'itemId' AS item_id FROM events WHERE type = 'loot.pickup' AND pid = $1",
    [pid],
  );
  const ownedIds = ownedRows.rows.map((row) => row.item_id).filter((id): id is string => id !== null);

  const runsRow = await pool.query<{ runs: number | null }>("SELECT runs FROM player_stats WHERE pid = $1", [pid]);
  const runsPlayed = runsRow.rows[0]?.runs ?? 0;

  return { cooccur, counts, allItemIds: [...allItemIds], ownedIds, runsPlayed };
}

function tagReason(recs: Recommendation[], reason: RecommendReason): RecommendResponseItem[] {
  return recs.map((r) => ({ ...r, reason }));
}

export async function registerRecommendRoutes(app: FastifyInstance): Promise<void> {
  app.get<{ Querystring: { pid?: string } }>("/v1/recommend/loadout", async (request, reply) => {
    const pid = request.query.pid;
    if (typeof pid !== "string" || pid === "") {
      return reply.code(400).send({ error: "bad_request", message: "pid query param required" });
    }

    const { cooccur, counts, allItemIds, ownedIds, runsPlayed } = await fetchLoadoutData(app, pid);
    const result = recommend(runsPlayed, ownedIds, allItemIds, cooccur, counts, DEFAULT_N);

    // docs/06's response shows a `reason` per item. This worker only
    // implements two of the three documented reason codes -- topN's
    // item-item similarity ("pairs_with_owned") and the popularity
    // fallback ("popular_at_your_rating"). "similar_players" would need a
    // genuinely different (player-based, not item-based) similarity
    // computation that doesn't exist yet; not fabricated here.
    const reason: RecommendReason = result.fallback ? "popular_at_your_rating" : "pairs_with_owned";
    const response: RecommendResponse = {
      recommendations: tagReason(result.recommendations, reason),
      fallback: result.fallback,
    };
    return reply.send(response);
  });
}
