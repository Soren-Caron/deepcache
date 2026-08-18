/**
 * M4-2. Loads the versioned OVERSEER system prompt.
 *
 * The version string ships in director.decision telemetry (M4-6), so a
 * prompt change is attributable in the metrics without guessing which
 * revision produced a given run.
 */

import { readFileSync } from "node:fs";

export const OVERSEER_PROMPT_VERSION = "v1";

let cached: string | undefined;

export function loadOverseerPrompt(): string {
  if (cached === undefined) {
    cached = readFileSync(
      new URL(`./prompts/overseer.${OVERSEER_PROMPT_VERSION}.md`, import.meta.url),
      "utf-8",
    );
  }
  return cached;
}
