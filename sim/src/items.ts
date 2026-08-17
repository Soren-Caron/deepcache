/**
 * Mirrors src/shared/config/Loot.luau. Duplicated rather than imported --
 * sim/ is a standalone package with no build-time link to the game's Luau
 * source -- but kept in the same shape and with the same item ids, so
 * simulated `loot.pickup` events describe the same economy the real game
 * does instead of a parallel fictional one.
 */

export interface ItemDef {
  readonly id: string;
  readonly rarity: "common" | "uncommon" | "rare" | "prototype";
  readonly weight: number;
  readonly baseValue: number;
}

export const ITEMS: readonly ItemDef[] = [
  { id: "scrap_bundle", rarity: "common", weight: 6, baseValue: 40 },
  { id: "cell_pack", rarity: "common", weight: 4, baseValue: 55 },
  { id: "optics_module", rarity: "uncommon", weight: 9, baseValue: 180 },
  { id: "coolant_flask", rarity: "uncommon", weight: 7, baseValue: 160 },
  { id: "servo_array", rarity: "rare", weight: 16, baseValue: 620 },
  { id: "archive_core", rarity: "rare", weight: 22, baseValue: 780 },
  { id: "overseer_shard", rarity: "prototype", weight: 30, baseValue: 2400 },
];

export const RARITY_MULTIPLIER: Record<ItemDef["rarity"], number> = {
  common: 1.0,
  uncommon: 2.4,
  rare: 6.0,
  prototype: 15.0,
};

export function valueOf(item: ItemDef): number {
  return item.baseValue * RARITY_MULTIPLIER[item.rarity];
}
