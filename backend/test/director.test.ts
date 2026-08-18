import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { OllamaClientError, type OllamaChatResult, type OllamaClient } from "../src/llm/ollama.js";

/**
 * M4-3. "Mocked client" is the accept criterion, not an implementation
 * detail -- a real Ollama call here would make this suite slow and flaky in
 * exactly the way the rest of this project's tests deliberately aren't (see
 * ingest.test.ts's real-Postgres philosophy for the opposite case, where a
 * mock would prove nothing). Here the thing under test is this route's own
 * error handling, which a mock can exercise deterministically in ways a
 * real, occasionally-slow local model cannot.
 */

const RUN_STATE = {
  runId: "01HX9F3K2M",
  t: 312,
  squad: [{ pid: "a3f9", hp: 62, weight: 47, kills: 14, deaths: 0, zone: "Processing" }],
  pressure: { aliveEnemies: 18, budgetSpent: 34, recentPlayerDamage: 210, recentEnemyDeaths: 22 },
  pacing: { secondsSinceLastFight: 4, secondsSinceLastLull: 96, fsmState: "PRESSURE" },
  objective: { active: "hold_terminal", progress: 0.4 },
  history: [] as string[],
};

async function buildAppWithClient(callOllama: OllamaClient): Promise<FastifyInstance> {
  process.env["NODE_ENV"] = "test";
  const app = await buildApp({ config: loadConfig(), logger: false, director: { callOllama } });
  await app.ready();
  return app;
}

function okResult(content: string, extra: Partial<OllamaChatResult> = {}): OllamaChatResult {
  return { content, promptEvalCount: 371, evalCount: 42, ...extra };
}

describe("POST /v1/director/tick", () => {
  let app: FastifyInstance;

  afterAll(async () => {
    if (app) await app.close();
  });

  it("happy path: valid structured JSON comes back as the proposal, unclamped", async () => {
    const proposal = {
      intent: "punish_greed",
      spawnMultiplier: 1.2,
      spawnPattern: "hunt_heaviest",
      objective: { id: "hold_terminal", params: { durationS: 45 } },
      threatTier: 4,
      bark: "The heavy one.",
    };
    app = await buildAppWithClient(async () => okResult(JSON.stringify(proposal)));

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.proposal).toEqual(proposal);
    expect(body.error).toBeUndefined();
    expect(body.promptEvalCount).toBe(371);
    expect(body.evalCount).toBe(42);
    expect(typeof body.latencyMs).toBe("number");
    expect(body.model).toBe("llama3.2:3b");
    expect(body.promptVersion).toBe("v1");
  });

  it("recovers a proposal wrapped in prose via the fallback extractor", async () => {
    const proposal = { intent: "hold_steady", spawnMultiplier: 1.0, spawnPattern: "even", objective: { id: "hold_terminal", params: {} }, threatTier: 3, bark: "Steady." };
    app = await buildAppWithClient(async () =>
      okResult(`Sure, here you go: ${JSON.stringify(proposal)} -- let me know if you need more.`),
    );

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json().proposal).toEqual(proposal);
    expect(res.json().error).toBeUndefined();
  });

  it("timeout: proposal is null, error is 'timeout', still a 200", async () => {
    app = await buildAppWithClient(async () => {
      throw new OllamaClientError({ kind: "timeout" });
    });

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ proposal: null, error: "timeout" });
  });

  it("ollama_error (local equivalent of a cloud 429 -- GPU busy, non-2xx from Ollama): proposal is null", async () => {
    app = await buildAppWithClient(async () => {
      throw new OllamaClientError({ kind: "ollama_error", status: 500, message: "model busy" });
    });

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ proposal: null, error: "ollama_error" });
  });

  it("unreachable: proposal is null, error is 'unreachable'", async () => {
    app = await buildAppWithClient(async () => {
      throw new OllamaClientError({ kind: "unreachable", message: "ECONNREFUSED" });
    });

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ proposal: null, error: "unreachable" });
  });

  it("malformed JSON that even the fallback extractor can't parse: proposal is null", async () => {
    app = await buildAppWithClient(async () => okResult("I cannot comply with that request."));

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ proposal: null, error: "malformed_json" });
    // Token counts still logged even on a parse failure -- the call itself
    // succeeded, only the content was unusable, and that's still billable
    // signal for prompt-quality debugging.
    expect(res.json().promptEvalCount).toBe(371);
  });

  it("empty response body from the model: proposal is null, error is 'empty_response'", async () => {
    app = await buildAppWithClient(async () => okResult("   "));

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ proposal: null, error: "empty_response" });
  });

  it("missing request body: 400, not a 500 and not a silent fallback shape", async () => {
    app = await buildAppWithClient(async () => okResult("{}"));

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: undefined });
    expect(res.statusCode).toBe(400);
  });

  it("a JSON array response (valid JSON, wrong shape) is treated as malformed, not as a proposal", async () => {
    app = await buildAppWithClient(async () => okResult("[1,2,3]"));

    const res = await app.inject({ method: "POST", url: "/v1/director/tick", payload: RUN_STATE });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ proposal: null, error: "malformed_json" });
  });
});
