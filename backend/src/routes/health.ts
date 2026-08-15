/**
 * Liveness and metrics.
 *
 * /healthz  — is the process up? No dependencies checked, so it stays green
 *             during a Postgres outage. That is deliberate: the game degrades
 *             gracefully without the database, so a DB outage is not a reason
 *             to have the orchestrator restart a working process.
 * /readyz   — are dependencies reachable? Gains a real DB probe at M3.
 * /metrics  — Prometheus text format.
 */

import type { FastifyInstance } from "fastify";
import { API_VERSION } from "../app.js";

export async function registerHealthRoutes(app: FastifyInstance): Promise<void> {
  app.get("/healthz", async () => ({
    status: "ok" as const,
    version: API_VERSION,
    uptimeSeconds: Math.floor((Date.now() - app.startedAt) / 1000),
  }));

  app.get("/readyz", async (_request, reply) => {
    const checks: Record<string, "ok" | "unchecked" | "failed"> = {
      // M3 replaces this with a real `SELECT 1`.
      database: "unchecked",
    };
    const failed = Object.values(checks).some((v) => v === "failed");
    return reply.code(failed ? 503 : 200).send({
      status: failed ? "degraded" : "ready",
      checks,
    });
  });

  app.get("/metrics", async (_request, reply) => {
    const uptime = (Date.now() - app.startedAt) / 1000;
    const lines = [
      "# HELP deepcache_up Whether the backend process is running.",
      "# TYPE deepcache_up gauge",
      "deepcache_up 1",
      "# HELP deepcache_uptime_seconds Seconds since process start.",
      "# TYPE deepcache_uptime_seconds gauge",
      `deepcache_uptime_seconds ${uptime.toFixed(3)}`,
    ];
    return reply.header("content-type", "text/plain; version=0.0.4").send(lines.join("\n") + "\n");
  });
}
