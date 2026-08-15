import { describe, expect, it, beforeAll, afterAll } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp, API_VERSION } from "../src/app.js";
import { loadConfig } from "../src/config.js";

describe("health routes", () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    process.env["NODE_ENV"] = "test";
    app = await buildApp({ config: loadConfig(), logger: false });
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  it("GET /healthz returns 200 and the version", async () => {
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: "ok", version: API_VERSION });
  });

  it("GET /healthz stays green without a database", async () => {
    // Liveness must not depend on Postgres: the game degrades gracefully
    // without it, so a DB outage should not trigger a process restart.
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(res.statusCode).toBe(200);
  });

  it("GET /readyz reports per-dependency checks", async () => {
    const res = await app.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toHaveProperty("checks.database");
  });

  it("GET /metrics returns Prometheus text format", async () => {
    const res = await app.inject({ method: "GET", url: "/metrics" });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toContain("text/plain");
    expect(res.body).toContain("deepcache_up 1");
  });

  it("unknown routes return a structured 404", async () => {
    const res = await app.inject({ method: "GET", url: "/nope" });
    expect(res.statusCode).toBe(404);
    expect(res.json()).toMatchObject({ error: "not_found" });
  });
});

describe("config", () => {
  it("supplies dev defaults so the repo runs with zero setup", () => {
    process.env["NODE_ENV"] = "test";
    const config = loadConfig();
    expect(config.port).toBe(8787);
    expect(config.databaseUrl).toContain("postgres://");
  });

  it("refuses to boot in production without secrets", () => {
    const saved = { ...process.env };
    try {
      process.env["NODE_ENV"] = "production";
      delete process.env["INGEST_SECRET"];
      delete process.env["PLAYER_SALT"];
      expect(() => loadConfig()).toThrow(/INGEST_SECRET/);
    } finally {
      process.env = saved;
    }
  });

  it("rejects a non-integer PORT rather than silently defaulting", () => {
    const saved = process.env["PORT"];
    try {
      process.env["NODE_ENV"] = "test";
      process.env["PORT"] = "not-a-number";
      expect(() => loadConfig()).toThrow(/PORT/);
    } finally {
      if (saved === undefined) delete process.env["PORT"];
      else process.env["PORT"] = saved;
    }
  });
});
