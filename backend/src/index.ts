/**
 * Process entry point.
 */

import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { getPool } from "./db.js";
import { callOllama } from "./llm/ollama.js";
import { loadOverseerPrompt } from "./llm/prompt.js";
import { DIRECTOR_JSON_SCHEMA } from "./llm/schema.js";
import { warmUpModel } from "./llm/warmup.js";
import { startRollupWorker } from "./rollup.js";
import { startEconomyWorker } from "./workers/economy.js";
import { TICK_KEEP_ALIVE } from "./routes/director.js";
import { startRecommendWorker } from "./workers/recommend.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const app = await buildApp({ config });

  // docs/04 §Workers: rollup runs on an interval inside the same process.
  // Started here, not in buildApp -- a timer started by every test that
  // builds an app would outlive the test and hang the suite on exit.
  const rollupTimer = startRollupWorker(getPool(config));
  // docs/06 §Loadout recommendations: "computed nightly." Same started-
  // outside-buildApp reasoning as the rollup timer above.
  const recommendTimer = startRecommendWorker(getPool(config));
  // docs/07 §The controller: the PI loop runs nightly over a trailing 24h
  // ledger window. Same started-outside-buildApp reasoning as the two above.
  const economyTimer = startEconomyWorker(getPool(config));

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info({ signal }, "shutting down");
    clearInterval(rollupTimer);
    clearInterval(recommendTimer);
    clearInterval(economyTimer);
    try {
      await app.close();
      process.exit(0);
    } catch (error) {
      app.log.error({ err: error }, "error during shutdown");
      process.exit(1);
    }
  };

  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));

  await app.listen({ port: config.port, host: config.host });
  app.log.info(
    { port: config.port, host: config.host, env: config.nodeEnv },
    "deepcache backend listening",
  );

  // Not awaited: warming can legitimately take ~20-40s from a genuinely cold
  // model, and the backend must be serving ingest, dashboard, and recommend
  // routes long before that finishes. Director ticks arriving mid-warm-up
  // fall back to the FSM baseline exactly as they already do -- the point is
  // only that they stop doing so permanently. See llm/warmup.ts for the
  // measured cold-start trap this breaks.
  void warmUpModel({
    baseUrl: config.ollamaBaseUrl,
    model: config.ollamaTickModel,
    keepAlive: TICK_KEEP_ALIVE,
    system: loadOverseerPrompt(),
    jsonSchema: DIRECTOR_JSON_SCHEMA,
    callOllama,
    log: (event, message) => app.log.info(event, message),
  });
}

main().catch((error: unknown) => {
  console.error("failed to start:", error);
  process.exit(1);
});
