/**
 * POST /v1/ingest — NDJSON batch of telemetry events.
 *
 * Three layers, in order: batch-level auth (HMAC over the whole body),
 * per-line validation (pure, see ingest/validate.ts), then a single bulk
 * insert that lets Postgres itself do the dedupe via the unique index on
 * (run_id, server_id, seq).
 *
 * Response shape is `{ accepted, rejected, duplicates }` — one field beyond
 * what docs/04 specifies. A replayed batch is neither new data nor an error:
 * counting it as `accepted` would make dedupe invisible to whoever reads the
 * response, and counting it as `rejected` would make a healthy retry look
 * like a client bug. It gets its own bucket instead.
 */

import { randomUUID } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { getPool } from "../db.js";
import { sign, verify } from "../hmac.js";
import { parseLine, type ParsedEnvelope } from "../ingest/validate.js";

const TIMESTAMP_SKEW_SECONDS = 300;

// docs/04's own acceptance criterion is a 10k-line batch in under 500ms;
// the cap has to sit comfortably above that or the documented budget is
// unreachable by construction. Headroom rather than an exact 10,000 so a
// slightly larger real-world batch (the buffer's own cap is 200 events per
// flush, so a single batch is normally tiny -- this bounds the pathological
// case of several missed flushes coalescing) is not rejected outright.
const MAX_LINES_PER_BATCH = 20000;

interface IngestResponse {
  accepted: number;
  rejected: number;
  duplicates: number;
}

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ error: "bad_request", message });
}

function unauthorized(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(401).send({ error: "unauthorized", message });
}

/**
 * Bulk insert via UNNEST rather than one INSERT per row. At 5,000 rows a
 * per-row round trip is the entire latency budget on its own; one
 * parameterized statement with array arguments is a single round trip and
 * lets Postgres's own dedupe (`ON CONFLICT DO NOTHING`) do the work instead
 * of a SELECT-then-INSERT racing against a concurrent batch from the same
 * server.
 */
async function insertBatch(
  app: FastifyInstance,
  rows: ParsedEnvelope[],
  serverId: string,
): Promise<number> {
  if (rows.length === 0) return 0;

  const ts = rows.map((r) => new Date(r.ts * 1000).toISOString());
  const runId = rows.map((r) => r.runId);
  const pid = rows.map((r) => r.pid);
  const type = rows.map((r) => r.type);
  const seq = rows.map((r) => r.seq);
  const payload = rows.map((r) => JSON.stringify(r.payload));

  const result = await getPool(app.config).query(
    `
    INSERT INTO events (ts, run_id, server_id, pid, type, seq, payload)
    SELECT ts, run_id, $7, pid, type, seq, payload::jsonb
    FROM UNNEST(
      $1::timestamptz[], $2::text[], $3::text[], $4::text[], $5::bigint[], $6::text[]
    ) AS t(ts, run_id, pid, type, seq, payload)
    ON CONFLICT (run_id, server_id, seq) DO NOTHING
    RETURNING id
    `,
    [ts, runId, pid, type, seq, payload, serverId],
  );
  return result.rowCount ?? 0;
}

export async function registerIngestRoute(app: FastifyInstance): Promise<void> {
  // Raw text body: NDJSON is not valid JSON, so Fastify's default parser
  // cannot handle it. The signature is computed over these exact bytes, so
  // the parser must hand back the untouched string, not a re-serialized one.
  app.addContentTypeParser("application/x-ndjson", { parseAs: "string" }, (_request, body, done) => {
    done(null, body);
  });

  app.post("/v1/ingest", async (request: FastifyRequest, reply: FastifyReply) => {
    const body = request.body;
    if (typeof body !== "string") {
      return badRequest(reply, "expected application/x-ndjson body");
    }

    const timestampHeader = request.headers["x-deepcache-timestamp"];
    const nonceHeader = request.headers["x-deepcache-nonce"];
    const signatureHeader = request.headers["x-deepcache-signature"];
    if (
      typeof timestampHeader !== "string" ||
      typeof nonceHeader !== "string" ||
      typeof signatureHeader !== "string"
    ) {
      return unauthorized(reply, "missing signature headers");
    }

    const timestamp = Number.parseInt(timestampHeader, 10);
    if (!Number.isFinite(timestamp)) {
      return unauthorized(reply, "invalid timestamp header");
    }
    // Bounds the window a captured request can be replayed in. The batch's
    // own dedupe already makes a replay a no-op for events already seen, but
    // this stops a captured signature being reused to smuggle a *new* seq
    // range in long after the original batch was sent.
    if (Math.abs(Date.now() / 1000 - timestamp) > TIMESTAMP_SKEW_SECONDS) {
      return unauthorized(reply, "timestamp outside allowed skew");
    }

    const expected = sign(app.config.ingestSecret, timestamp, nonceHeader, body);
    if (!verify(expected, signatureHeader.toLowerCase())) {
      return unauthorized(reply, "signature mismatch");
    }

    const lines = body.split("\n").filter((line) => line.trim().length > 0);
    if (lines.length > MAX_LINES_PER_BATCH) {
      return badRequest(reply, `batch of ${lines.length} exceeds ${MAX_LINES_PER_BATCH} lines`);
    }

    const valid: ParsedEnvelope[] = [];
    let rejected = 0;
    for (const line of lines) {
      const envelope = parseLine(line);
      if (envelope === null) {
        rejected += 1;
      } else {
        valid.push(envelope);
      }
    }

    // A batch can legitimately carry events from more than one server only
    // if something upstream merged batches, which nothing here does — every
    // envelope in one POST is expected to share a serverId. Anything that
    // does not match the first one is rejected individually rather than
    // failing the whole batch, so one confused line cannot cost its siblings.
    const serverId = valid[0]?.serverId;
    const sameServer = valid.filter((e) => e.serverId === serverId);
    rejected += valid.length - sameServer.length;

    let accepted = 0;
    if (serverId !== undefined) {
      const inserted = await insertBatch(app, sameServer, serverId);
      accepted = inserted;
    }
    const duplicates = sameServer.length - accepted;

    const response: IngestResponse = { accepted, rejected, duplicates };
    return reply.code(200).send(response);
  });
}

/** Exposed for the diagnostics bridge / local testing scripts, not a route. */
export function signBatch(secret: string, body: string): { timestamp: number; nonce: string; signature: string } {
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = randomUUID();
  return { timestamp, nonce, signature: sign(secret, timestamp, nonce, body) };
}
