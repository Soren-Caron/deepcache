/**
 * M4-3. Thin client for Ollama's native /api/chat.
 *
 * Deliberately not the OpenAI-compatible endpoint -- the native one exposes
 * `keep_alive` and `format` (a JSON Schema, not just "json") directly on the
 * request body, both load-bearing here: `keep_alive` is what prevents the
 * ~40s cold-start measured in docs/metrics/m4.md from reintroducing itself
 * mid-run, and `format` is the structured-output constraint the whole
 * fallback ladder exists as a backstop for, not a replacement of.
 */

export interface OllamaChatArgs {
  readonly baseUrl: string;
  readonly model: string;
  readonly system: string;
  readonly userContent: string;
  readonly jsonSchema: unknown;
  readonly timeoutMs: number;
  readonly keepAlive: string;
  readonly maxOutputTokens: number;
}

export interface OllamaChatResult {
  readonly content: string;
  readonly promptEvalCount: number | undefined;
  readonly evalCount: number | undefined;
}

export type OllamaError =
  | { readonly kind: "timeout" }
  | { readonly kind: "unreachable"; readonly message: string }
  | { readonly kind: "ollama_error"; readonly status: number; readonly message: string };

export type OllamaClient = (args: OllamaChatArgs) => Promise<OllamaChatResult>;

export class OllamaClientError extends Error {
  readonly detail: OllamaError;
  constructor(detail: OllamaError) {
    super(detail.kind);
    this.detail = detail;
  }
}

/** The real client. Tests inject a fake `OllamaClient` instead of this. */
export const callOllama: OllamaClient = async (args) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), args.timeoutMs);

  let response: Response;
  try {
    response = await fetch(`${args.baseUrl}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        model: args.model,
        stream: false,
        keep_alive: args.keepAlive,
        messages: [
          { role: "system", content: args.system },
          { role: "user", content: args.userContent },
        ],
        format: args.jsonSchema,
        options: { num_predict: args.maxOutputTokens },
      }),
    });
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      throw new OllamaClientError({ kind: "timeout" });
    }
    throw new OllamaClientError({
      kind: "unreachable",
      message: err instanceof Error ? err.message : String(err),
    });
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new OllamaClientError({ kind: "ollama_error", status: response.status, message: body });
  }

  const data = (await response.json()) as {
    message?: { content?: string };
    prompt_eval_count?: number;
    eval_count?: number;
  };

  return {
    content: data.message?.content ?? "",
    promptEvalCount: data.prompt_eval_count,
    evalCount: data.eval_count,
  };
};
