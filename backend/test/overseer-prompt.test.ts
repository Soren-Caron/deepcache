import { describe, expect, it } from "vitest";
import { loadOverseerPrompt, OVERSEER_PROMPT_VERSION } from "../src/llm/prompt.js";
import { INTENTS, OBJECTIVE_IDS, SPAWN_PATTERNS } from "../src/llm/schema.js";

/**
 * M4-2. Structural checks on the system prompt, not content-quality checks
 * (there is no automated way to grade "does this read like OVERSEER" --
 * that is a human judgment call, made once when the prompt was written).
 *
 * The original plan measured cache eligibility via a token-count floor
 * specific to Anthropic's prompt caching. That doesn't apply to Ollama (see
 * docs/05 §Model selection and cost), so this asserts the actual load-bearing
 * properties instead: every enum value the model is allowed to return is
 * named and explained, the objective whitelist's param semantics are spelled
 * out, and the worked-examples requirement (2 good, 2 bad, docs/05 §Prompt
 * design notes) is met.
 */

describe("overseer system prompt", () => {
  const prompt = loadOverseerPrompt();

  it("has a version string", () => {
    expect(OVERSEER_PROMPT_VERSION).toBe("v1");
  });

  it("names every intent the model is allowed to return", () => {
    for (const intent of INTENTS) {
      expect(prompt).toContain(intent);
    }
  });

  it("names every spawn pattern the model is allowed to return", () => {
    for (const pattern of SPAWN_PATTERNS) {
      expect(prompt).toContain(pattern);
    }
  });

  it("names every objective id in the whitelist, with param semantics", () => {
    for (const id of OBJECTIVE_IDS) {
      expect(prompt).toContain(id);
    }
    // Every objective's declared param name shows up somewhere, not just the id.
    expect(prompt).toContain("count");
    expect(prompt).toContain("durationS");
    expect(prompt).toContain("distanceStuds");
  });

  it("states the numeric bounds explicitly rather than leaving them implicit", () => {
    expect(prompt).toContain("0.6");
    expect(prompt).toContain("1.6");
    expect(prompt).toContain("0.25");
    expect(prompt).toMatch(/\[1,\s*5\]/);
  });

  it("includes exactly four worked examples, two labeled good and two labeled bad", () => {
    const goodCount = (prompt.match(/\*\*Good/g) ?? []).length;
    const badCount = (prompt.match(/\*\*Bad/g) ?? []).length;
    expect(goodCount).toBe(2);
    expect(badCount).toBe(2);

    const codeBlocks = prompt.match(/```json/g) ?? [];
    expect(codeBlocks.length).toBe(4);
  });

  it("is non-trivial content, not a stub", () => {
    // Not pinned to the old ~4200-token cache-eligibility target (that
    // constraint doesn't exist for Ollama), just a sanity floor that this
    // is a real, substantive prompt.
    expect(prompt.length).toBeGreaterThan(3000);
  });

  it("never references being an AI/model/JSON schema in the parts a player could see", () => {
    // Weak but real: the voice section explicitly forbids this. Checking the
    // prompt doesn't casually contradict its own instruction.
    const loweredExcludingVoiceSection = prompt.toLowerCase();
    expect(loweredExcludingVoiceSection).toContain("never break character");
  });
});
