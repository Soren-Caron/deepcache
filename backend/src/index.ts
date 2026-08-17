/**
 * Process entry point.
 */

import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { getPool } from "./db.js";
import { startRollupWorker } from "./rollup.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const app = await buildApp({ config });

  // docs/04 §Workers: rollup runs on an interval inside the same process.
  // Started here, not in buildApp -- a timer started by every test that
  // builds an app would outlive the test and hang the suite on exit.
  const rollupTimer = startRollupWorker(getPool(config));

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info({ signal }, "shutting down");
    clearInterval(rollupTimer);
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
}

main().catch((error: unknown) => {
  console.error("failed to start:", error);
  process.exit(1);
});
