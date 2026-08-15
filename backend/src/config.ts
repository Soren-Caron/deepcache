/**
 * Environment configuration, validated once at import.
 *
 * Fails fast and loudly: a backend that boots with a missing secret and then
 * 500s on the first real request is worse than one that refuses to start.
 */

export interface Config {
  readonly port: number;
  readonly host: string;
  readonly nodeEnv: "development" | "test" | "production";
  readonly databaseUrl: string;
  /** HMAC secret shared with game servers. Required outside development. */
  readonly ingestSecret: string;
  /** Salt for pseudonymising player IDs. Never leaves the backend. */
  readonly playerSalt: string;
  /** Absent until M4; the director route checks for it at call time. */
  readonly anthropicApiKey: string | undefined;
}

function optional(name: string): string | undefined {
  const value = process.env[name];
  return value === undefined || value === "" ? undefined : value;
}

function withDefault(name: string, fallback: string): string {
  return optional(name) ?? fallback;
}

function intWithDefault(name: string, fallback: number): number {
  const raw = optional(name);
  if (raw === undefined) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) {
    throw new Error(`env ${name} must be an integer, got ${JSON.stringify(raw)}`);
  }
  return parsed;
}

function parseNodeEnv(): Config["nodeEnv"] {
  const raw = withDefault("NODE_ENV", "development");
  if (raw === "development" || raw === "test" || raw === "production") return raw;
  throw new Error(`env NODE_ENV must be development|test|production, got ${JSON.stringify(raw)}`);
}

export function loadConfig(): Config {
  const nodeEnv = parseNodeEnv();
  const isProd = nodeEnv === "production";

  // Dev/test defaults exist so the repo runs with zero setup. Production has
  // no defaults for secrets — an unset secret must be a boot failure, not a
  // silently insecure deployment.
  const ingestSecret = optional("INGEST_SECRET");
  const playerSalt = optional("PLAYER_SALT");

  if (isProd) {
    const missing: string[] = [];
    if (!ingestSecret) missing.push("INGEST_SECRET");
    if (!playerSalt) missing.push("PLAYER_SALT");
    if (missing.length > 0) {
      throw new Error(`missing required env in production: ${missing.join(", ")}`);
    }
  }

  return {
    port: intWithDefault("PORT", 8787),
    host: withDefault("HOST", "127.0.0.1"),
    nodeEnv,
    databaseUrl: withDefault(
      "DATABASE_URL",
      "postgres://deepcache:deepcache@127.0.0.1:5432/deepcache",
    ),
    ingestSecret: ingestSecret ?? "dev-insecure-ingest-secret",
    playerSalt: playerSalt ?? "dev-insecure-player-salt",
    anthropicApiKey: optional("ANTHROPIC_API_KEY"),
  };
}
