/**
 * Five player archetypes, docs/04's "sim/ run simulator with the five
 * archetypes." Each is a distribution over the choices a real player makes,
 * not a fixed script -- two runs from the same archetype and different seeds
 * should look like two different people who play the same way, not two
 * identical replays.
 */

export interface Archetype {
  readonly name: string;
  /** Probability this player extracts rather than dies, before weight risk. */
  readonly extractChance: number;
  /** How much loot they're willing to carry before deciding to leave. */
  readonly greedWeightCap: number;
  /** Shots fired per minute of the run -- how much they fight vs. avoid it. */
  readonly firesPerMinute: number;
  /** Fraction of shots that land. */
  readonly accuracy: number;
  readonly preferredWeapons: readonly string[];
}

export const ARCHETYPES: readonly Archetype[] = [
  {
    name: "cautious",
    extractChance: 0.82,
    greedWeightCap: 35,
    firesPerMinute: 4,
    accuracy: 0.55,
    preferredWeapons: ["Sidearm"],
  },
  {
    name: "looter",
    // Greed cap far outstrips extractChance's safety margin on purpose: this
    // archetype is "the weight tension" from docs/01 personified -- it dies
    // to its own carry weight more often than to a clean fight.
    extractChance: 0.58,
    greedWeightCap: 90,
    firesPerMinute: 6,
    accuracy: 0.5,
    preferredWeapons: ["Sidearm", "Slug"],
  },
  {
    name: "aggressive",
    extractChance: 0.6,
    greedWeightCap: 45,
    firesPerMinute: 22,
    accuracy: 0.62,
    preferredWeapons: ["Carbine", "Arc"],
  },
  {
    name: "average",
    extractChance: 0.68,
    greedWeightCap: 50,
    firesPerMinute: 10,
    accuracy: 0.58,
    preferredWeapons: ["Sidearm", "Carbine"],
  },
  {
    name: "reckless",
    extractChance: 0.4,
    greedWeightCap: 75,
    firesPerMinute: 28,
    accuracy: 0.45,
    preferredWeapons: ["Carbine", "Slug", "Arc"],
  },
];
