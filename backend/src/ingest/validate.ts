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

/**
 * Upper bound on `ts`, in seconds. JS `Date` is only defined over
 * ±8.64e15 **milliseconds**, and `routes/ingest.ts` converts with
 * `new Date(ts * 1000)`, so anything past this makes `.toISOString()` throw
 * `RangeError: Invalid time value`. That throw escapes the route handler,
 * turns the POST into a 500, and destroys every valid line that happened to
 * share the batch — the precise failure that per-line validation exists to
 * contain. Bounding it here keeps a bad line a *line* problem.
 */
const MAX_TS_SECONDS = 8.64e12;

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
 * `Number.isSafeInteger` is typed `(n: unknown) => boolean` in TS's lib, not
 * as a type predicate, so it does not narrow `unknown`. This wrapper does,
 * which keeps the call sites free of `as number` casts.
 */
function isSafeInt(value: unknown): value is number {
  return Number.isSafeInteger(value);
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

  // `Number.isSafeInteger` rather than `Number.isInteger` throughout: the
  // latter is true for 1e20, which then overflows the `seq` column's Postgres
  // `bigint` (max ~9.22e18) and fails the *whole* INSERT. Past 2^53 two
  // distinct wire values can also collide into the same JS number, so a seq
  // above the safe range cannot do the one job seq has (ordering/dedupe).
  if (!isSafeInt(v) || v < 1) return null;
  if (!isFiniteNumber(ts) || ts <= 0 || ts > MAX_TS_SECONDS) return null;
  if (!isNonEmptyString(runId, MAX_ID_LENGTH)) return null;
  if (!isNonEmptyString(serverId, MAX_ID_LENGTH)) return null;
  if (!isSafeInt(placeId) || placeId < 0) return null;
  if (pid !== undefined && pid !== null && !isNonEmptyString(pid, MAX_ID_LENGTH)) return null;
  if (!isNonEmptyString(type, MAX_TYPE_LENGTH)) return null;
  if (!isSafeInt(seq) || seq < 1) return null;
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
