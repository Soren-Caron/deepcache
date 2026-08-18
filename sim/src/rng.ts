/**
 * Deterministic seeded PRNG. A separate implementation from
 * core/shared/util/Rng.luau -- this is TypeScript with no reason to share a
 * runtime with Luau -- but the same algorithm (xorshift32) and the same
 * contract: same seed, same sequence, every time.
 *
 * Determinism matters here for the same reason it matters in the game:
 * `npm run generate -- --runs 2000 --seed 1` reproduces byte-identical
 * synthetic data, which is what makes a dashboard bug reproducible instead
 * of "it looked different when I ran it again."
 */

export class Rng {
  private state: number;

  constructor(seed: number) {
    const s = Math.floor(seed) >>> 0;
    this.state = s === 0 ? 0x9e3779b9 : s;
  }

  nextInt(): number {
    let s = this.state;
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    this.state = s >>> 0;
    return this.state;
  }

  nextFloat(): number {
    return this.nextInt() / 4294967296;
  }

  nextRange(min: number, max: number): number {
    if (max < min) throw new Error(`nextRange: max (${max}) < min (${min})`);
    const span = max - min + 1;
    return min + (this.nextInt() % span);
  }

  chance(probability: number): boolean {
    return this.nextFloat() < probability;
  }

  pick<T>(list: readonly T[]): T {
    if (list.length === 0) throw new Error("pick: empty list");
    const item = list[this.nextRange(0, list.length - 1)];
    if (item === undefined) throw new Error("pick: unreachable index");
    return item;
  }

  /** Standard normal (mean 0, stddev 1) via Box-Muller. */
  nextGaussian(): number {
    // nextFloat() can return exactly 0, which would make log(u1) = -Infinity.
    const u1 = Math.max(this.nextFloat(), Number.EPSILON);
    const u2 = this.nextFloat();
    return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  }

  /** Exponential inter-arrival time for a Poisson process at `ratePerSecond`. */
  nextExponential(ratePerSecond: number): number {
    const u = Math.max(this.nextFloat(), Number.EPSILON);
    return -Math.log(u) / ratePerSecond;
  }
}
