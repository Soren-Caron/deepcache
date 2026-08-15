/**
 * Application factory.
 *
 * Separated from index.ts so tests can build an app and use `inject()`
 * without binding a port.
 */

import Fastify, { type FastifyError, type FastifyInstance } from "fastify";
import type { Config } from "./config.js";
import { registerHealthRoutes } from "./routes/health.js";

export const API_VERSION = "0.1.0";

export interface BuildOptions {
  readonly config: Config;
  readonly logger?: boolean;
}

export async function buildApp(options: BuildOptions): Promise<FastifyInstance> {
  const app = Fastify({
    // Tests pass logger:false, which also silences request logging — no need
    // for the deprecated `disableRequestLogging` option.
    logger: options.logger ?? options.config.nodeEnv !== "test",
    // Game servers batch telemetry; a single flush can be large.
    bodyLimit: 8 * 1024 * 1024,
  });

  app.decorate("config", options.config);
  app.decorate("startedAt", Date.now());

  await app.register(registerHealthRoutes);

  app.setNotFoundHandler((request, reply) => {
    void reply.code(404).send({
      error: "not_found",
      message: `no route for ${request.method} ${request.url}`,
    });
  });

  app.setErrorHandler((error: FastifyError, request, reply) => {
    request.log.error({ err: error }, "unhandled error");
    const status = error.statusCode ?? 500;
    void reply.code(status).send({
      error: status >= 500 ? "internal_error" : "bad_request",
      // Never leak internals on a 5xx.
      message: status >= 500 ? "internal error" : error.message,
    });
  });

  return app;
}

declare module "fastify" {
  interface FastifyInstance {
    config: Config;
    startedAt: number;
  }
}
