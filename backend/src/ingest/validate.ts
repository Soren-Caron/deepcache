/**
 * Envelope validation. Pure — no database, no HTTP — so it is tested at unit
 * speed and independently of everything that can go wrong with a connection
 * to Postgres. Mirrors the pure-core / thin-adapter split the Luau side uses:
 * this is the "core", `routes/ingest.ts` is the "adapter".
 */

export interface ParsedEnvelope {
  readonly v: number;
  readonly ts: number;
  readonly runId: string;
  readonly serverId: string;
  readonly pid: string | null;
  readonly type: string;
  readonly seq: number;
  readonly payload: Record<string, unknown>;
}

const MAX_ID_LENGTH = 200;
const MAX_TYPE_LENGTH = 64;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown, maxLength: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

/**
 * Validate one decoded JSON line against the envelope shape the game client
 * emits (`core/telemetry/Buffer.Envelope`). Returns `null` — never throws —
 * so a caller iterating a batch can skip a bad line and keep processing its
 * siblings, which is the whole point of NDJSON over a single JSON array.
 */
export function validateEnvelope(value: unknown): ParsedEnvelope | null {
  if (!isPlainObject(value)) return null;

  const { v, ts, runId, serverId, placeId, pid, type, seq, p } = value as Record<string, unknown>;

  if (!isFiniteNumber(v) || v < 1 || !Number.isInteger(v)) return null;
  if (!isFiniteNumber(ts) || ts <= 0) return null;
  if (!isNonEmptyString(runId, MAX_ID_LENGTH)) return null;
  if (!isNonEmptyString(serverId, MAX_ID_LENGTH)) return null;
  if (!isFiniteNumber(placeId) || placeId < 0 || !Number.isInteger(placeId)) return null;
  if (pid !== undefined && pid !== null && !isNonEmptyString(pid, MAX_ID_LENGTH)) return null;
  if (!isNonEmptyString(type, MAX_TYPE_LENGTH)) return null;
  if (!isFiniteNumber(seq) || seq < 1 || !Number.isInteger(seq)) return null;
  if (!isPlainObject(p)) return null;

  return {
    v,
    ts,
    runId,
    serverId,
    pid: pid === undefined ? null : (pid as string | null),
    type,
    seq,
    payload: p,
  };
}

/**
 * One line of an NDJSON body: parse, then validate. Never throws.
 *
 * Blank lines are the caller's concern, not this function's: a trailing
 * newline is a normal artifact of how the body was joined, not a malformed
 * event, and the route filters blank lines out before counting rejections so
 * that artifact never inflates the reject count.
 */
export function parseLine(line: string): ParsedEnvelope | null {
  try {
    return validateEnvelope(JSON.parse(line));
  } catch {
    return null;
  }
}
