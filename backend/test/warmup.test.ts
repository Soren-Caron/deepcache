import { describe, expect, it } from "vitest";
import { OllamaClientError, type OllamaChatArgs, type OllamaClient } from "../src/llm/ollama.js";
import { warmUpModel, WARMUP_TIMEOUT_MS } from "../src/llm/warmup.js";

/**
 * The warm-up exists to break a cold-start trap measured during the M2-M6
 * audit pass: a tick request is aborted at 1200ms, a cold model load takes
 * far longer, an aborted request never establishes `keep_alive`, so the model
 * stays cold and every subsequent tick fails identically -- observed live as
 * `fallbacks` climbing with `timeout` on every tick and no recovery.
 *
 * Mocked deliberately (same reasoning as director.test.ts): what is under
 * test is that the warm-up asks for a long deadline, pins the model, and
 * never takes the process down -- all of which a fake can assert
 * deterministically, unlike a real local model whose load time varies by
 * tens of seconds.
 */

const BASE = {
  baseUrl: "http://127.0.0.1:11434",
  model: "llama3.2:3b",
  keepAlive: "30m",
  system: "system prompt",
  jsonSchema: { type: "object" },
};

describe("warmUpModel", () => {
  it("uses a deadline long enough to outlast a real cold load", async () => {
    // The whole point. A warm-up on the tick budget would abort mid-load and
    // recreate the trap it exists to break; docs/metrics/m4.md measured a
    // genuine cold load at ~21.7s.
    let seen: OllamaChatArgs | undefined;
    const fake: OllamaClient = async (args) => {
      seen = args;
      return { content: "{}", promptEvalCount: 1, evalCount: 1 };
    };

    const result = await warmUpModel({ ...BASE, callOllama: fake });

    expect(result.ok).toBe(true);
    expect(seen?.timeoutMs).toBe(WARMUP_TIMEOUT_MS);
    expect(WARMUP_TIMEOUT_MS).toBeGreaterThan(21_700);
  });

  it("pins the model with keep_alive, which is what stops it going cold again", async () => {
    let seen: OllamaChatArgs | undefined;
    const fake: OllamaClient = async (args) => {
      seen = args;
      return { content: "{}", promptEvalCount: 1, evalCount: 1 };
    };

    await warmUpModel({ ...BASE, callOllama: fake });

    expect(seen?.keepAlive).toBe("30m");
    expect(seen?.model).toBe("llama3.2:3b");
  });

  it("sends the real system prompt so the prompt-prefix cache is warmed too", async () => {
    // Measured: after the weights were warm, the first request carrying the
    // full ~2300-token system prompt still took 1.21s and timed out, while
    // the ones after it landed at 0.85-1.0s. Loading weights alone is not
    // sufficient to get under the tick budget.
    let seen: OllamaChatArgs | undefined;
    const fake: OllamaClient = async (args) => {
      seen = args;
      return { content: "{}", promptEvalCount: 1, evalCount: 1 };
    };

    await warmUpModel({ ...BASE, system: "the-overseer-prompt", callOllama: fake });

    expect(seen?.system).toBe("the-overseer-prompt");
  });

  it("never throws when Ollama is unreachable, so the backend still starts", async () => {
    const fake: OllamaClient = async () => {
      throw new OllamaClientError({ kind: "unreachable", message: "ECONNREFUSED" });
    };

    const result = await warmUpModel({ ...BASE, callOllama: fake });

    expect(result.ok).toBe(false);
    expect(result.error).toBe("unreachable");
  });

  it("never throws on an unexpected non-Ollama error either", async () => {
    const fake: OllamaClient = async () => {
      throw new Error("something else entirely");
    };

    const result = await warmUpModel({ ...BASE, callOllama: fake });

    expect(result.ok).toBe(false);
    expect(result.error).toContain("something else entirely");
  });

  it("reports the failure through the log hook rather than silently", async () => {
    const logged: string[] = [];
    const fake: OllamaClient = async () => {
      throw new OllamaClientError({ kind: "timeout" });
    };

    await warmUpModel({
      ...BASE,
      callOllama: fake,
      log: (_event, message) => logged.push(message),
    });

    expect(logged).toHaveLength(1);
    expect(logged[0]).toContain("warm-up failed");
  });
});
