/**
 * M4-3. POST /v1/director/tick — proxies a run-state summary to Ollama and
 * returns the raw model proposal.
 *
 * This route does NOT clamp. Clamp.apply lives in src/shared/core/director/
 * Clamp.luau (M4-5) per CLAUDE.md's one rule -- gameplay logic is pure Luau,
 * and "what decision actually applies to the run" is gameplay logic. This
 * route's only job is: call the model, and hand back either a proposal or a
 * clear reason there isn't one. The Roblox-side DirectorService (M4-6) is
 * what calls Clamp.apply(proposal, fsmBaseline, bounds).
 *
 * Every failure mode returns 200 with `proposal: null` and an `error`
 * field, not a non-2xx status -- the caller's job in every one of these
 * cases is identical (fall back to the FSM baseline), so there is no
 * behavioral difference for it to branch on, and forcing it to distinguish
 * "the request failed" from "the model failed" would be a distinction
 * without a difference here. A malformed *request* (no body at all) is the
 * one genuine 400 -- that's a caller bug, not a model-availability problem.
 */

import type { FastifyInstance } from "fastify";
import { extractBalancedJson } from "../llm/fallback.js";
import { callOllama as defaultCallOllama, OllamaClientError, type OllamaClient } from "../llm/ollama.js";
import { loadOverseerPrompt, OVERSEER_PROMPT_VERSION } from "../llm/prompt.js";
import { DIRECTOR_JSON_SCHEMA } from "../llm/schema.js";

/** docs/05 §Cadence and latency. */
export const TICK_TIMEOUT_MS = 1200;
/** Long enough to outlive the gap between 20s ticks; see docs/metrics/m4.md cold-start numbers. */
export const TICK_KEEP_ALIVE = "30m";
/**
 * Measured, not guessed: a real full-prompt tick call generated a complete,
 * valid decision in 93 output tokens at ~8.5ms/token on the target hardware
 * (docs/metrics/m4.md). Output generation, not prompt processing, is the
 * dominant cost -- prompt_eval for the full ~2300-token prompt was only
 * ~110ms. 400 would allow a worst-case ~3.4s generation if the model ever
 * rambled past the schema; 150 gives real headroom over the observed 93
 * while still hard-capping runaway output well inside the tick budget.
 */
const MAX_OUTPUT_TOKENS = 150;

export type DirectorTickErrorReason =
  | "timeout"
  | "unreachable"
  | "ollama_error"
  | "malformed_json"
  | "empty_response";

export interface DirectorTickResponse {
  readonly proposal: unknown | null;
  readonly latencyMs: number;
  readonly model: string;
  readonly promptVersion: string;
  readonly promptEvalCount?: number | undefined;
  readonly evalCount?: number | undefined;
  readonly error?: DirectorTickErrorReason;
}

export interface DirectorRouteOptions {
  /** Defaults to the real Ollama HTTP client; tests inject a fake. */
  readonly callOllama?: OllamaClient;
}

export async function registerDirectorRoutes(
  app: FastifyInstance,
  options: DirectorRouteOptions = {},
): Promise<void> {
  const callOllama = options.callOllama ?? defaultCallOllama;

  app.post("/v1/director/tick", async (request, reply) => {
    const runState = request.body;
    if (runState === undefined || runState === null || typeof runState !== "object") {
      return reply.code(400).send({ error: "bad_request", message: "run-state body required" });
    }

    const model = app.config.ollamaTickModel;
    const start = performance.now();

    const respond = (
      partial: Omit<DirectorTickResponse, "latencyMs" | "model" | "promptVersion">,
    ): DirectorTickResponse => ({
      ...partial,
      latencyMs: performance.now() - start,
      model,
      promptVersion: OVERSEER_PROMPT_VERSION,
    });

    let result;
    try {
      result = await callOllama({
        baseUrl: app.config.ollamaBaseUrl,
        model,
        system: loadOverseerPrompt(),
        userContent: JSON.stringify(runState),
        jsonSchema: DIRECTOR_JSON_SCHEMA,
        timeoutMs: TICK_TIMEOUT_MS,
        keepAlive: TICK_KEEP_ALIVE,
        maxOutputTokens: MAX_OUTPUT_TOKENS,
      });
    } catch (err) {
      if (err instanceof OllamaClientError) {
        return reply.send(respond({ proposal: null, error: err.detail.kind }));
      }
      throw err;
    }

    const trimmed = result.content.trim();
    if (trimmed === "") {
      return reply.send(
        respond({
          proposal: null,
          error: "empty_response",
          promptEvalCount: result.promptEvalCount,
          evalCount: result.evalCount,
        }),
      );
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      parsed = extractBalancedJson(trimmed);
    }

    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return reply.send(
        respond({
          proposal: null,
          error: "malformed_json",
          promptEvalCount: result.promptEvalCount,
          evalCount: result.evalCount,
        }),
      );
    }

    return reply.send(
      respond({
        proposal: parsed,
        promptEvalCount: result.promptEvalCount,
        evalCount: result.evalCount,
      }),
    );
  });
}
