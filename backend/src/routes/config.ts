/**
 * M6-5. GET /v1/config -- the live economy config game servers pull.
 *
 * Serves the highest `economy_config` version. The *version guard* proper
 * lives on the game side (`core/economy/ConfigGuard.luau`: ignore anything
 * not strictly newer than what I already hold), because that is where the
 * decision has consequences -- a server that has already adopted version 9
 * must not be talked back to version 8 by a stale replica or a replayed
 * response. Serving it is this route's job; trusting it is not.
 *
 * `?since=` is an optimisation, not the guard: a caller can say what it has
 * and get `304`-style `{ current: false }` instead of a payload it would
 * discard anyway. Behaviour is identical whether or not the caller uses it.
 *
 * What this route *does* enforce is that it never serves a config the game
 * would be right to reject. The controller already clamps to
 * `[MULT_MIN, MULT_MAX]`, but a manual INSERT into `economy_config` bypasses
 * the controller entirely, and shipping an out-of-range multiplier to every
 * live server is the kind of mistake that is only funny in hindsight. A row
 * that fails validation is skipped in favour of the newest one that passes,
 * and the skip is logged -- serving a stale-but-valid config is strictly
 * better than serving a poisoned one, and better than 500ing every server's
 * boot-time pull.
 */

import type { FastifyInstance } from "fastify";
import { getPool } from "../db.js";
import { MULT_MAX, MULT_MIN } from "../economy/controller.js";

export interface EconomyConfigPayload {
  readonly version: number;
  readonly payoutMultiplier: number;
  readonly source: string;
}

export interface ConfigResponse {
  readonly current: boolean;
  readonly config: EconomyConfigPayload | null;
}

interface ConfigRow {
  version: string;
  multiplier: string;
  source: string;
}

/** Every rule a config row must satisfy before it is fit to ship. */
export function validateConfigRow(row: {
  version: number;
  multiplier: number;
}): { ok: true } | { ok: false; reason: string } {
  if (!Number.isSafeInteger(row.version) || row.version < 1) {
    return { ok: false, reason: "version must be a positive integer" };
  }
  if (!Number.isFinite(row.multiplier)) {
    return { ok: false, reason: "multiplier is not finite" };
  }
  if (row.multiplier < MULT_MIN || row.multiplier > MULT_MAX) {
    return {
      ok: false,
      reason: `multiplier ${row.multiplier} outside [${MULT_MIN}, ${MULT_MAX}]`,
    };
  }
  return { ok: true };
}

export async function registerConfigRoutes(app: FastifyInstance): Promise<void> {
  app.get("/v1/config", async (request, reply) => {
    const query = request.query as { since?: string } | undefined;
    const sinceRaw = query?.since;
    const since = sinceRaw === undefined ? 0 : Number.parseInt(sinceRaw, 10);
    if (sinceRaw !== undefined && !Number.isSafeInteger(since)) {
      return reply.code(400).send({ error: "bad_request", message: "since must be an integer" });
    }

    // Newest first, so the first row that validates is the newest valid one.
    const result = await getPool(app.config).query<ConfigRow>(
      `SELECT version, multiplier, source FROM economy_config ORDER BY version DESC LIMIT 25`,
    );

    for (const row of result.rows) {
      const candidate = {
        version: Number(row.version),
        multiplier: Number(row.multiplier),
        source: row.source,
      };
      const verdict = validateConfigRow(candidate);
      if (!verdict.ok) {
        app.log.warn(
          { version: candidate.version, reason: verdict.reason },
          "economy_config row failed validation; skipping to an older valid version",
        );
        continue;
      }
      if (candidate.version <= since) {
        const response: ConfigResponse = { current: true, config: null };
        return reply.send(response);
      }
      const response: ConfigResponse = {
        current: false,
        config: {
          version: candidate.version,
          payoutMultiplier: candidate.multiplier,
          source: candidate.source,
        },
      };
      return reply.send(response);
    }

    // Nothing valid to serve. The game falls back to its compiled-in
    // defaults, which is exactly what M6-6 does when the backend is
    // unreachable -- one fallback path, not two.
    const response: ConfigResponse = { current: false, config: null };
    return reply.send(response);
  });
}
