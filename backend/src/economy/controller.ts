/**
 * M6-5. TypeScript mirror of `core/economy/Controller.luau`.
 *
 * The backend cannot `require` a `.luau` file, so the PI controller exists
 * twice -- same reason `discovery/recommend.ts` mirrors `Recommend.luau`.
 * The constants and the formula are the ones docs/07 §The controller
 * specifies, and `test/economy-worker.test.ts` checks this implementation
 * against the exact values `tests/controller.spec.luau` pins on the Luau
 * side, so the two cannot drift silently.
 *
 * The controller runs here rather than in-game because it needs a trailing
 * 24h window over every server's ledger, which only the backend can see. The
 * *result* is what ships to game servers, as a config version.
 */

export const TARGET_RATIO = 0.85;
export const KP = 0.35;
export const KI = 0.05;
export const I_MAX = 2.0;
export const MULT_MIN = 0.8;
export const MULT_MAX = 1.25;
export const MAX_DAILY_DELTA = 0.03;
export const MIN_RUNS = 200;

const CLAMP_EPSILON = 1e-9;

export interface ControllerState {
  readonly multiplier: number;
  readonly integral: number;
  readonly clampedDays: number;
}

export interface Observation {
  readonly faucetTotal: number;
  readonly sinkTotal: number;
  readonly runCount: number;
}

export interface Decision {
  readonly multiplier: number;
  readonly applied: boolean;
  readonly reason: string;
  readonly ratio: number;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

export function initialState(): ControllerState {
  return { multiplier: 1.0, integral: 0, clampedDays: 0 };
}

/**
 * One nightly update. A skip returns `state` byte-for-byte unchanged,
 * including `integral` -- a day that did not count must not accumulate error,
 * or the next real update reacts to a day that never happened.
 */
export function step(
  state: ControllerState,
  obs: Observation,
  enabled: boolean,
): { state: ControllerState; decision: Decision } {
  const ratio = obs.sinkTotal / Math.max(obs.faucetTotal, 1);

  if (!enabled) {
    return {
      state,
      decision: { multiplier: state.multiplier, applied: false, reason: "autotune disabled", ratio },
    };
  }
  if (obs.runCount < MIN_RUNS) {
    return {
      state,
      decision: {
        multiplier: state.multiplier,
        applied: false,
        reason: `sample too small (${obs.runCount} < ${MIN_RUNS})`,
        ratio,
      },
    };
  }

  const err = TARGET_RATIO - ratio;
  const newIntegral = clamp(state.integral + err, -I_MAX, I_MAX);
  const adjust = KP * err + KI * newIntegral;

  const rangeClamped = clamp(state.multiplier * (1 - adjust), MULT_MIN, MULT_MAX);
  const delta = clamp(rangeClamped - state.multiplier, -MAX_DAILY_DELTA, MAX_DAILY_DELTA);
  const newMultiplier = state.multiplier + delta;

  const atClamp =
    newMultiplier <= MULT_MIN + CLAMP_EPSILON || newMultiplier >= MULT_MAX - CLAMP_EPSILON;

  return {
    state: {
      multiplier: newMultiplier,
      integral: newIntegral,
      clampedDays: atClamp ? state.clampedDays + 1 : 0,
    },
    decision: { multiplier: newMultiplier, applied: true, reason: "updated", ratio },
  };
}
