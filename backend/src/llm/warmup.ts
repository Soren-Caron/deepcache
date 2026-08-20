/**
 * Model warm-up, so the tick path's own timeout cannot trap the director in
 * a permanent cold state.
 *
 * **The trap this exists to break, measured during the M2-M6 audit pass, not
 * theorised.** docs/metrics/m4.md says the ~40s cold start is "mitigated with
 * `keep_alive` pinned on every request." That mitigation only holds for a
 * request Ollama actually *finishes*. A tick request is aborted at 1200ms
 * (`AbortController` in ollama.ts), and a cold load takes far longer than
 * that -- 3.1s on a warm GPU with the model merely evicted, ~21.7s on the
 * original cold measurement. So from a cold model the sequence is:
 *
 *   tick -> load starts -> abort at 1200ms -> load abandoned, no keep_alive
 *   -> model still cold -> next tick -> identical failure, forever.
 *
 * Observed live in Studio: `fallbacks` climbing 5, 7, 8, 9 with `timeout` on
 * every single tick and no recovery, while the backend correctly returned
 * `{"error":"timeout"}` in ~1.21s each time. The director had silently
 * degraded to pure-FSM and would never have come back on its own. It only
 * recovered after an out-of-band Ollama call with no tight deadline.
 *
 * The fix is not a longer tick budget -- the 1200ms budget is a real
 * gameplay constraint from docs/05 and should stay strict. It is to load and
 * pin the model once, out of band, with a deadline generous enough to
 * actually complete. After that every tick hits a warm model and the pin is
 * refreshed by the ticks themselves, which is what the doc assumed all along.
 */

import { OllamaClientError, type OllamaChatArgs, type OllamaClient } from "./ollama.js";

/**
 * Generous on purpose: this must outlast a genuine cold load (~21.7s in the
 * original docs/metrics/m4.md measurement) or it recreates the very trap it
 * exists to break. Nothing is waiting on it -- see `warmUpModel`'s contract.
 */
export const WARMUP_TIMEOUT_MS = 90_000;

export interface WarmUpArgs {
  readonly baseUrl: string;
  readonly model: string;
  readonly keepAlive: string;
  readonly system: string;
  readonly jsonSchema: unknown;
  /** Injected in tests; defaults to the real client at the call site. */
  readonly callOllama: OllamaClient;
  readonly log?: (event: Record<string, unknown>, message: string) => void;
}

export interface WarmUpResult {
  readonly ok: boolean;
  readonly elapsedMs: number;
  readonly error?: string;
}

/**
 * Load and pin the tick model. Never throws and never rejects: a backend that
 * cannot reach Ollama must still start and serve every other route, and the
 * director already degrades to the FSM baseline on its own. The result is
 * returned for logging and tests rather than signalled by an exception.
 */
export async function warmUpModel(args: WarmUpArgs): Promise<WarmUpResult> {
  const started = Date.now();
  const request: OllamaChatArgs = {
    baseUrl: args.baseUrl,
    model: args.model,
    system: args.system,
    // Deliberately a real, tick-shaped request rather than an empty ping: it
    // populates the prompt-prefix cache for the ~2300-token system prompt as
    // well as loading the weights. Measured, both matter -- the first request
    // after the weights were warm still took 1.21s and timed out, while the
    // ones after it landed in 0.85-1.0s.
    userContent: JSON.stringify({ warmup: true }),
    jsonSchema: args.jsonSchema,
    timeoutMs: WARMUP_TIMEOUT_MS,
    keepAlive: args.keepAlive,
    maxOutputTokens: 16,
  };

  try {
    await args.callOllama(request);
    const elapsedMs = Date.now() - started;
    args.log?.({ model: args.model, elapsedMs }, "ollama model warmed and pinned");
    return { ok: true, elapsedMs };
  } catch (err) {
    const elapsedMs = Date.now() - started;
    const error = err instanceof OllamaClientError ? err.detail.kind : String(err);
    args.log?.(
      { model: args.model, elapsedMs, error },
      "ollama warm-up failed; director will fall back to the FSM baseline until it succeeds",
    );
    return { ok: false, elapsedMs, error };
  }
}
