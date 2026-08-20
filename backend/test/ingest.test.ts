import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { closePool, getPool } from "../src/db.js";
import { sign } from "../src/hmac.js";

/**
 * Runs against the real local Postgres (docker-compose), not a mock. The
 * dedupe guarantee this suite exists to prove — a replayed batch inserts
 * zero rows — is enforced by a database constraint, and a mock would only
 * prove that the mock was written to agree with the code under test.
 */

let app: FastifyInstance;
let counter = 0;

/** A fresh runId per test avoids needing to truncate the table between
 * tests, except where a test specifically wants to reuse one (the replay
 * case). */
function freshRunId(): string {
  counter += 1;
  return `test-run-${Date.now()}-${counter}`;
}

function envelope(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    v: 1,
    ts: 1700000000,
    runId: freshRunId(),
    serverId: "test-server",
    placeId: 1,
    pid: "pid-1",
    type: "combat.hit",
    seq: 1,
    p: { damage: 22 },
    ...overrides,
  };
}

function ndjson(envelopes: Record<string, unknown>[]): string {
  return envelopes.map((e) => JSON.stringify(e)).join("\n");
}

async function post(
  body: string,
  secret: string,
): Promise<{ statusCode: number; json: () => any }> {
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = "test-nonce";
  const signature = sign(secret, timestamp, nonce, body);
  const res = await app.inject({
    method: "POST",
    url: "/v1/ingest",
    headers: {
      "content-type": "application/x-ndjson",
      "x-deepcache-timestamp": String(timestamp),
      "x-deepcache-nonce": nonce,
      "x-deepcache-signature": signature,
    },
    payload: body,
  });
  return { statusCode: res.statusCode, json: () => res.json() };
}

beforeAll(async () => {
  process.env["NODE_ENV"] = "test";
  const config = loadConfig();
  // Schema reset happens once, in test/global-setup.ts, before any test file
  // runs -- not here. Two files each dropping and recreating the same live
  // tables is a race if vitest runs them in parallel, which it does by
  // default.
  app = await buildApp({ config, logger: false });
  await app.ready();
});

afterAll(async () => {
  await app.close();
  await closePool();
});

describe("POST /v1/ingest — auth", () => {
  it("accepts a correctly signed batch", async () => {
    const body = ndjson([envelope()]);
    const res = await post(body, "dev-ingest-secret-change-me");
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ accepted: 1, rejected: 0, duplicates: 0 });
  });

  it("rejects a batch signed with the wrong secret", async () => {
    const body = ndjson([envelope()]);
    const res = await post(body, "wrong-secret");
    expect(res.statusCode).toBe(401);
  });

  it("rejects a batch whose body does not match what was signed", async () => {
    const config = loadConfig();
    const signedBody = ndjson([envelope()]);
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = "tamper-test";
    const signature = sign(config.ingestSecret, timestamp, nonce, signedBody);

    // Same signature, different body -- as if a line were appended after
    // signing.
    const tamperedBody = signedBody + "\n" + JSON.stringify(envelope());
    const res = await app.inject({
      method: "POST",
      url: "/v1/ingest",
      headers: {
        "content-type": "application/x-ndjson",
        "x-deepcache-timestamp": String(timestamp),
        "x-deepcache-nonce": nonce,
        "x-deepcache-signature": signature,
      },
      payload: tamperedBody,
    });
    expect(res.statusCode).toBe(401);
  });

  it("rejects a request with a stale timestamp", async () => {
    const config = loadConfig();
    const body = ndjson([envelope()]);
    const staleTimestamp = Math.floor(Date.now() / 1000) - 3600; // 1 hour old
    const nonce = "stale-test";
    const signature = sign(config.ingestSecret, staleTimestamp, nonce, body);
    const res = await app.inject({
      method: "POST",
      url: "/v1/ingest",
      headers: {
        "content-type": "application/x-ndjson",
        "x-deepcache-timestamp": String(staleTimestamp),
        "x-deepcache-nonce": nonce,
        "x-deepcache-signature": signature,
      },
      payload: body,
    });
    expect(res.statusCode).toBe(401);
  });

  it("rejects a request with missing signature headers", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/ingest",
      headers: { "content-type": "application/x-ndjson" },
      payload: ndjson([envelope()]),
    });
    expect(res.statusCode).toBe(401);
  });
});

describe("POST /v1/ingest — validation", () => {
  const secret = "dev-ingest-secret-change-me";

  it("rejects a malformed line while its siblings commit", async () => {
    const good1 = envelope();
    const good2 = envelope();
    const body = [JSON.stringify(good1), "{ not valid json", JSON.stringify(good2)].join("\n");
    const res = await post(body, secret);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ accepted: 2, rejected: 1, duplicates: 0 });
  });

  it("rejects a line that parses as JSON but fails schema validation", async () => {
    const good = envelope();
    const badShape = { not: "an envelope" };
    const body = [JSON.stringify(good), JSON.stringify(badShape)].join("\n");
    const res = await post(body, secret);
    expect(res.json()).toEqual({ accepted: 1, rejected: 1, duplicates: 0 });
  });

  it("ignores blank lines without counting them as rejected", async () => {
    const body = `${JSON.stringify(envelope())}\n\n\n`;
    const res = await post(body, secret);
    expect(res.json()).toEqual({ accepted: 1, rejected: 0, duplicates: 0 });
  });

  it("rejects every line of an empty or all-garbage batch without erroring", async () => {
    const res = await post("not json at all\nneither is this", secret);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ accepted: 0, rejected: 2, duplicates: 0 });
  });

  // The three cases below are regressions for a real bug found in an audit
  // pass, not hypotheticals. `ts` and `seq` were validated only as "finite"
  // and "an integer >= 1" respectively, with no upper bound. Both are then
  // handed to something with a much narrower real domain:
  //   - ts  -> `new Date(ts * 1000).toISOString()`, which THROWS RangeError
  //            once ts exceeds ~8.64e12 (JS Date's +-8.64e15 ms limit).
  //   - seq -> a Postgres `bigint` column, which errors above ~9.22e18.
  // Either one escaping validation takes down the whole POST with a 500 and
  // loses every valid sibling line in the batch -- the exact failure mode
  // per-line validation exists to prevent.
  it("rejects an out-of-range ts instead of 500ing and losing the whole batch", async () => {
    const good = envelope();
    const body = [JSON.stringify(good), JSON.stringify(envelope({ ts: 1e13 }))].join("\n");
    const res = await post(body, secret);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ accepted: 1, rejected: 1, duplicates: 0 });
  });

  it("rejects a seq beyond bigint range instead of 500ing and losing the whole batch", async () => {
    const good = envelope();
    const body = [JSON.stringify(good), JSON.stringify(envelope({ seq: 1e20 }))].join("\n");
    const res = await post(body, secret);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ accepted: 1, rejected: 1, duplicates: 0 });
  });

  it("still accepts a ts at the top of the sane range", async () => {
    // Guards against over-correcting: a plausible far-future timestamp must
    // keep working, only genuinely unrepresentable ones are rejected.
    const res = await post(ndjson([envelope({ ts: 4102444800 })]), secret); // 2100-01-01
    expect(res.json()).toEqual({ accepted: 1, rejected: 0, duplicates: 0 });
  });
});

describe("POST /v1/ingest — dedupe", () => {
  const secret = "dev-ingest-secret-change-me";

  it("replaying an identical batch inserts zero new rows", async () => {
    const runId = freshRunId();
    const body = ndjson([
      envelope({ runId, seq: 1 }),
      envelope({ runId, seq: 2 }),
      envelope({ runId, seq: 3 }),
    ]);

    const first = await post(body, secret);
    expect(first.json()).toEqual({ accepted: 3, rejected: 0, duplicates: 0 });

    const replay = await post(body, secret);
    expect(replay.json()).toEqual({ accepted: 0, rejected: 0, duplicates: 3 });

    const config = loadConfig();
    const count = await getPool(config).query(
      "SELECT count(*)::int AS n FROM events WHERE run_id = $1",
      [runId],
    );
    expect(count.rows[0].n).toBe(3);
  });

  it("a partially-overlapping retry accepts only the new events", async () => {
    const runId = freshRunId();
    const first = await post(ndjson([envelope({ runId, seq: 1 }), envelope({ runId, seq: 2 })]), secret);
    expect(first.json().accepted).toBe(2);

    // A retry that includes seq 2 (already landed) plus a genuinely new seq 3
    // -- the real shape of "client retried after a timeout, but the first
    // attempt had actually landed."
    const retry = await post(
      ndjson([envelope({ runId, seq: 2 }), envelope({ runId, seq: 3 })]),
      secret,
    );
    expect(retry.json()).toEqual({ accepted: 1, rejected: 0, duplicates: 1 });
  });

  it("does not dedupe across different servers with the same seq", async () => {
    // seq is monotonic per server, not globally; two servers legitimately
    // produce seq=1 independently and both must land.
    const runId = freshRunId();
    const a = await post(ndjson([envelope({ runId, serverId: "server-a", seq: 1 })]), secret);
    const b = await post(ndjson([envelope({ runId, serverId: "server-b", seq: 1 })]), secret);
    expect(a.json().accepted).toBe(1);
    expect(b.json().accepted).toBe(1);
  });
});

describe("POST /v1/ingest — payload integrity", () => {
  it("stores the payload queryable as JSONB, not as an opaque string", async () => {
    const config = loadConfig();
    const runId = freshRunId();
    const body = ndjson([envelope({ runId, p: { damage: 22, headshot: true } })]);
    await post(body, "dev-ingest-secret-change-me");

    const result = await getPool(config).query(
      "SELECT payload FROM events WHERE run_id = $1",
      [runId],
    );
    expect(result.rows[0].payload).toEqual({ damage: 22, headshot: true });
  });

  it("round-trips ts as the same instant, not a re-parsed approximation", async () => {
    const config = loadConfig();
    const runId = freshRunId();
    const ts = 1712345678;
    await post(ndjson([envelope({ runId, ts })]), "dev-ingest-secret-change-me");

    const result = await getPool(config).query("SELECT ts FROM events WHERE run_id = $1", [runId]);
    const stored = new Date(result.rows[0].ts as Date).getTime();
    expect(stored).toBe(ts * 1000);
  });
});

describe("POST /v1/ingest — performance", () => {
  it("ingests a 10,000-line batch in under 500ms", async () => {
    // docs/04's own acceptance criterion, verified against the real
    // Postgres this suite runs against rather than a mock -- a mock would
    // only prove the bulk-insert query is well-formed, not that it is fast.
    const runId = freshRunId();
    const envelopes = Array.from({ length: 10000 }, (_, i) =>
      envelope({ runId, seq: i + 1, type: "perf.tick" }),
    );
    const body = ndjson(envelopes);

    const started = performance.now();
    const res = await post(body, "dev-ingest-secret-change-me");
    const elapsedMs = performance.now() - started;

    expect(res.json()).toEqual({ accepted: 10000, rejected: 0, duplicates: 0 });
    expect(elapsedMs).toBeLessThan(500);
  });
});
