/**
 * M5-10. TypeScript mirror of `core/discovery/Recommend.luau`'s scoring
 * math -- the backend cannot `require` a `.luau` file, so this is a
 * second, independent implementation of the same formulas, the same
 * relationship `llm/schema.ts` has to `Schema.luau`. `test/recommend-sync.
 * test.ts` asserts both agree on the same hand-computed cases, so a drift
 * between them is caught, not assumed away.
 */

export const SHRINKAGE = 10;
export const COLD_START_RUNS = 3;

export interface Recommendation {
  readonly itemId: string;
  readonly score: number;
}

export interface RecommendResult {
  readonly recommendations: Recommendation[];
  readonly fallback: boolean;
}

export function similarity(cooccurCount: number, countA: number, countB: number): number {
  if (countA <= 0 || countB <= 0 || cooccurCount <= 0) return 0;
  const cosine = cooccurCount / Math.sqrt(countA * countB);
  return (cosine * cooccurCount) / (cooccurCount + SHRINKAGE);
}

function scoreItem(
  candidateId: string,
  ownedIds: readonly string[],
  cooccur: ReadonlyMap<string, ReadonlyMap<string, number>>,
  counts: ReadonlyMap<string, number>,
): number {
  let total = 0;
  const candidateCount = counts.get(candidateId) ?? 0;
  const row = cooccur.get(candidateId);
  for (const ownedId of ownedIds) {
    const pairCount = row?.get(ownedId) ?? 0;
    total += similarity(pairCount, candidateCount, counts.get(ownedId) ?? 0);
  }
  return total;
}

function sortDescending(recs: Recommendation[]): Recommendation[] {
  return [...recs].sort((a, b) => (a.score !== b.score ? b.score - a.score : a.itemId.localeCompare(b.itemId)));
}

export function topN(
  allItemIds: readonly string[],
  ownedIds: readonly string[],
  cooccur: ReadonlyMap<string, ReadonlyMap<string, number>>,
  counts: ReadonlyMap<string, number>,
  n: number,
): Recommendation[] {
  const owned = new Set(ownedIds);
  const candidates: Recommendation[] = [];
  for (const itemId of allItemIds) {
    if (owned.has(itemId)) continue;
    const score = scoreItem(itemId, ownedIds, cooccur, counts);
    if (score > 0) candidates.push({ itemId, score });
  }
  return sortDescending(candidates).slice(0, n);
}

export function popularityBaseline(
  allItemIds: readonly string[],
  counts: ReadonlyMap<string, number>,
  ownedIds: readonly string[],
  n: number,
): Recommendation[] {
  const owned = new Set(ownedIds);
  const candidates: Recommendation[] = [];
  for (const itemId of allItemIds) {
    if (owned.has(itemId)) continue;
    const count = counts.get(itemId) ?? 0;
    if (count > 0) candidates.push({ itemId, score: count });
  }
  return sortDescending(candidates).slice(0, n);
}

export function recommend(
  runsPlayed: number,
  ownedIds: readonly string[],
  allItemIds: readonly string[],
  cooccur: ReadonlyMap<string, ReadonlyMap<string, number>>,
  counts: ReadonlyMap<string, number>,
  n: number,
): RecommendResult {
  if (runsPlayed < COLD_START_RUNS) {
    return { recommendations: popularityBaseline(allItemIds, counts, ownedIds, n), fallback: true };
  }
  return { recommendations: topN(allItemIds, ownedIds, cooccur, counts, n), fallback: false };
}
