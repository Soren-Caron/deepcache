/**
 * `npm run generate -- --runs 2000 --days 30`
 *
 * Generates N synthetic runs spread across the last `days` days, across the
 * five archetypes, and posts them to a real running backend's /v1/ingest --
 * the same endpoint and the same signed-NDJSON wire format the game server
 * uses. This is what makes the dashboard (M3-7) show something before a
 * single real player has ever run the game, and what gives the rollup
 * worker (M3-5) and the ingest dedupe path (M3-3) real volume to prove
 * themselves against instead of a handful of manually-triggered events.
 */

import { config as loadDotenv } from "dotenv";
import { ARCHETYPES, generateRun, type Envelope, type Player } from "./generateRun.js";
import { sign } from "./hmac.js";
import { Rng } from "./rng.js";

loadDotenv();

interface Args {
  runs: number;
  days: number;
  seed: number;
  baseUrl: string;
  secret: string;
}

function parseArgs(argv: string[]): Args {
  const get = (flag: string, fallback: string): string => {
    const index = argv.indexOf(flag);
    return index !== -1 && argv[index + 1] !== undefined ? (argv[index + 1] as string) : fallback;
  };
  return {
    runs: Number.parseInt(get("--runs", "500"), 10),
    days: Number.parseInt(get("--days", "30"), 10),
    seed: Number.parseInt(get("--seed", "1"), 10),
    baseUrl: process.env["SIM_BACKEND_URL"] ?? "http://127.0.0.1:8787",
    // Matches backend/.env's INGEST_SECRET and Backend.luau's sharedSecret
    // for the local dev loop, same as the game server's default.
    secret: process.env["INGEST_SECRET"] ?? "dev-ingest-secret-change-me",
  };
}

const SERVER_POOL_SIZE = 40;
const PLAYER_POOL_SIZE = 300;
const MAX_LINES_PER_POST = 15000; // headroom under the backend's 20,000 cap

function buildPlayerPool(rng: Rng, size: number): Player[] {
  const players: Player[] = [];
  for (let i = 0; i < size; i += 1) {
    players.push({
      pid: `sim-player-${i.toString(36)}`,
      archetype: rng.pick(ARCHETYPES),
    });
  }
  return players;
}

async function postBatch(baseUrl: string, secret: string, envelopes: Envelope[]): Promise<{ accepted: number; rejected: number; duplicates: number }> {
  const body = envelopes.map((e) => JSON.stringify(e)).join("\n");
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = `sim-${Math.random().toString(36).slice(2)}`;
  const signature = sign(secret, timestamp, nonce, body);

  const response = await fetch(`${baseUrl}/v1/ingest`, {
    method: "POST",
    headers: {
      "content-type": "application/x-ndjson",
      "x-deepcache-timestamp": String(timestamp),
      "x-deepcache-nonce": nonce,
      "x-deepcache-signature": signature,
    },
    body,
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`ingest returned ${response.status}: ${text.slice(0, 300)}`);
  }
  return (await response.json()) as { accepted: number; rejected: number; duplicates: number };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  console.log(`generating ${args.runs} runs across ${args.days} days (seed ${args.seed}) -> ${args.baseUrl}`);

  const rng = new Rng(args.seed);
  const players = buildPlayerPool(rng, PLAYER_POOL_SIZE);
  const servers = Array.from({ length: SERVER_POOL_SIZE }, (_, i) => `sim-job-${i}`);

  const nowSeconds = Math.floor(Date.now() / 1000);
  const spanSeconds = args.days * 86400;

  let totals = { accepted: 0, rejected: 0, duplicates: 0 };
  let posted = 0;
  let runsCompleted = 0;
  const startedAt = performance.now();

  // A real game server flushes only its own buffer -- /v1/ingest rejects a
  // batch that mixes serverId, on the reasonable assumption that nothing
  // upstream merges two servers' telemetry into one POST. The first draft of
  // this generator batched runs from all 40 simulated servers together for
  // throughput and hit that rejection on ~80% of lines: a real bug in the
  // simulator, caught by actually running it against the real endpoint
  // rather than by inspecting the payload shape, which was fine on its own.
  // Assigning every run to a server up front and flushing per server fixes
  // it and is also the more honest simulation -- N servers, each flushing
  // independently, same as production.
  const runIndicesByServer = new Map<string, number[]>();
  for (const server of servers) runIndicesByServer.set(server, []);
  for (let run = 0; run < args.runs; run += 1) {
    const server = rng.pick(servers);
    runIndicesByServer.get(server)?.push(run);
  }

  for (const [server, runIndices] of runIndicesByServer) {
    let pending: Envelope[] = [];

    const flush = async (): Promise<void> => {
      if (pending.length === 0) return;
      const result = await postBatch(args.baseUrl, args.secret, pending);
      totals = {
        accepted: totals.accepted + result.accepted,
        rejected: totals.rejected + result.rejected,
        duplicates: totals.duplicates + result.duplicates,
      };
      posted += 1;
      pending = [];
    };

    for (const run of runIndices) {
      const runId = `sim-${args.seed}-${run}`;
      const squadSize = rng.nextRange(1, 4);
      const squad: Player[] = [];
      for (let i = 0; i < squadSize; i += 1) squad.push(rng.pick(players));

      const startTs = nowSeconds - rng.nextRange(0, spanSeconds);
      const events = generateRun(rng, runId, server, squad, startTs);

      if (pending.length + events.length > MAX_LINES_PER_POST) {
        await flush();
      }
      pending.push(...events);

      runsCompleted += 1;
      if (runsCompleted % 200 === 0 || runsCompleted === args.runs) {
        process.stdout.write(`\r  ${runsCompleted}/${args.runs} runs generated`);
      }
    }
    await flush();
  }

  const elapsedS = (performance.now() - startedAt) / 1000;
  console.log(
    `\ndone in ${elapsedS.toFixed(1)}s, ${posted} batch(es): ` +
      `accepted=${totals.accepted} rejected=${totals.rejected} duplicates=${totals.duplicates}`,
  );
  if (totals.rejected > 0) {
    console.warn(`WARNING: ${totals.rejected} lines were rejected -- check envelope shape against backend/src/ingest/validate.ts`);
    process.exitCode = 1;
  }
}

main().catch((err: unknown) => {
  console.error("generate failed:", err);
  process.exitCode = 1;
});
