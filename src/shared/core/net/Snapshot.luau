--!strict
--[[
	Binary snapshot encode/decode with delta compression.

	Hard constraint: UnreliableRemoteEvent silently drops payloads over ~1000
	bytes, so MAX_BYTES is 900 and encode() asserts rather than letting a packet
	vanish in production. Do not raise it. See docs/03-NETCODE.md §Wire format.

	Layout — 5-byte header, then 11 bytes per entity:

	  header   tick           uint32   4
	           countAndFlags  uint8    1     bit7 = keyframe, bits0-6 = count
	  entity   id             uint16   2
	           x, y, z        int16    6     0.05-stud grid, relative to origin
	           yaw            uint8    1
	           state+kind     uint8    1     bits0-2 = state, bits3-5 = kind
	           hpPct          uint8    1

	Capacity is (900 - 5) / 11 = 81 entities. Interest management caps at 32,
	so there is headroom to add a field later without a format break.

	`kind` shares the state byte rather than taking a twelfth. There are six
	states and six entity kinds, three bits each, and the byte was carrying a
	value of 0-5 in isolation. The client needs kind to draw a Warden
	differently from a Skitter — without it every enemy is the same grey box —
	and paying a byte per entity per tick for information that fits in bits
	already being sent would be a real bandwidth cost for no reason.

	Divergence from the original spec: the plan described a 4-byte changed-entity
	bitfield prefix for deltas, indexed by position in the baseline. That
	requires the client and server to agree on entity ordering, which is fragile
	and buys nothing here — every record already carries its own uint16 id, so a
	delta is simply the subset of records that changed. The keyframe flag is
	packed into the spare high bit of the count byte, which keeps the header at
	the documented 5 bytes and the capacity at the documented 81.

	Deltas never remove entities. An entity leaving the interest set is sent as
	an explicit despawn on the reliable channel, because silently omitting it
	from an unreliable packet is indistinguishable from packet loss.
]]

local Types = require("../Types")
local Quantize = require("./Quantize")

export type Snapshot = {
	tick: number,
	isKeyframe: boolean,
	entities: { Types.EntityView },
}

--- An entity record with every field already quantized to its wire integer.
--- Delta comparison happens on these, not on floats: two positions a
--- micrometre apart encode identically and must not cost a slot.
export type Record = {
	id: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	state: number,
	hp: number,
}

local Snapshot = {}

Snapshot.MAX_BYTES = 900
Snapshot.HEADER_BYTES = 5
Snapshot.ENTITY_BYTES = 11
Snapshot.KEYFRAME_INTERVAL = 20

local COUNT_MASK = 0x7F
local KEYFRAME_BIT = 0x80
local MAX_ENTITY_ID = 65535

local STATE_TO_CODE: { [Types.EntityStateName]: number } = {
	idle = 0,
	move = 1,
	attack = 2,
	stagger = 3,
	death = 4,
	spawn = 5,
}

local CODE_TO_STATE: { [number]: Types.EntityStateName } = {}
for name, code in STATE_TO_CODE do
	CODE_TO_STATE[code] = name
end

--- Order is the wire format. Appending is safe; reordering or removing breaks
--- every client that has not shipped the same change.
local KIND_TO_CODE: { [Types.EntityKind]: number } = {
	Skitter = 0,
	Sentry = 1,
	Hauler = 2,
	Lancer = 3,
	Warden = 4,
	Reclaimer = 5,
}

local CODE_TO_KIND: { [number]: Types.EntityKind } = {}
for name, code in KIND_TO_CODE do
	CODE_TO_KIND[code] = name
end

local STATE_MASK = 0x07
local KIND_SHIFT = 3
--- Three bits, so six kinds fit with two values spare and bits 6-7 untouched.
local KIND_MASK = 0x07

Snapshot.STATE_TO_CODE = STATE_TO_CODE
Snapshot.CODE_TO_STATE = CODE_TO_STATE

--- How many entities fit in one packet. Used by interest management.
function Snapshot.capacity(): number
	return math.floor((Snapshot.MAX_BYTES - Snapshot.HEADER_BYTES) / Snapshot.ENTITY_BYTES)
end

function Snapshot.byteSize(entityCount: number): number
	return Snapshot.HEADER_BYTES + entityCount * Snapshot.ENTITY_BYTES
end

--------------------------------------------------------------------------------
-- Quantization
--------------------------------------------------------------------------------

--- EntityView -> wire integers, relative to the level origin.
function Snapshot.toRecord(view: Types.EntityView, origin: Types.Vec3): Record
	local id = view.id
	if id ~= math.floor(id) or id < 0 or id > MAX_ENTITY_ID then
		error(`Snapshot.toRecord: entity id {id} does not fit uint16`, 2)
	end
	local code = STATE_TO_CODE[view.state]
	if code == nil then
		error(`Snapshot.toRecord: unknown state "{tostring(view.state)}"`, 2)
	end
	local kindCode = KIND_TO_CODE[view.kind]
	if kindCode == nil then
		error(`Snapshot.toRecord: unknown kind "{tostring(view.kind)}"`, 2)
	end
	return {
		id = id,
		x = Quantize.encodePosition(view.pos.x - origin.x),
		y = Quantize.encodePosition(view.pos.y - origin.y),
		z = Quantize.encodePosition(view.pos.z - origin.z),
		yaw = Quantize.encodeYaw(view.yaw),
		state = bit32.bor(code, bit32.lshift(kindCode, KIND_SHIFT)),
		hp = Quantize.encodeUnit(view.hpPct),
	}
end

--- Wire integers -> EntityView, back in world space.
function Snapshot.fromRecord(record: Record, origin: Types.Vec3): Types.EntityView
	local state = CODE_TO_STATE[bit32.band(record.state, STATE_MASK)]
	if state == nil then
		error(`Snapshot.fromRecord: unknown state code {record.state}`, 2)
	end
	local kind = CODE_TO_KIND[bit32.band(bit32.rshift(record.state, KIND_SHIFT), KIND_MASK)]
	if kind == nil then
		error(`Snapshot.fromRecord: unknown kind code in state byte {record.state}`, 2)
	end
	return {
		id = record.id,
		kind = kind,
		pos = {
			x = Quantize.decodePosition(record.x) + origin.x,
			y = Quantize.decodePosition(record.y) + origin.y,
			z = Quantize.decodePosition(record.z) + origin.z,
		},
		yaw = Quantize.decodeYaw(record.yaw),
		state = state,
		hpPct = Quantize.decodeUnit(record.hp),
	}
end

function Snapshot.recordsEqual(a: Record, b: Record): boolean
	return a.id == b.id
		and a.x == b.x
		and a.y == b.y
		and a.z == b.z
		and a.yaw == b.yaw
		and a.state == b.state
		and a.hp == b.hp
end

--------------------------------------------------------------------------------
-- Buffer IO
--------------------------------------------------------------------------------

local function writeRecords(tick: number, records: { Record }, isKeyframe: boolean): buffer
	local count = #records
	local capacity = Snapshot.capacity()
	if count > capacity then
		error(
			`Snapshot: {count} entities exceeds the {Snapshot.MAX_BYTES}-byte budget `
				.. `(capacity {capacity}). Interest management must cap the set before encoding.`,
			3
		)
	end
	if tick ~= math.floor(tick) or tick < 0 or tick > 4294967295 then
		error(`Snapshot: tick {tick} does not fit uint32`, 3)
	end

	local size = Snapshot.byteSize(count)
	local b = buffer.create(size)

	buffer.writeu32(b, 0, tick)
	local countAndFlags = count
	if isKeyframe then
		countAndFlags = bit32.bor(countAndFlags, KEYFRAME_BIT)
	end
	buffer.writeu8(b, 4, countAndFlags)

	local offset = Snapshot.HEADER_BYTES
	for _, r in records do
		buffer.writeu16(b, offset, r.id)
		buffer.writei16(b, offset + 2, r.x)
		buffer.writei16(b, offset + 4, r.y)
		buffer.writei16(b, offset + 6, r.z)
		buffer.writeu8(b, offset + 8, r.yaw)
		buffer.writeu8(b, offset + 9, r.state)
		buffer.writeu8(b, offset + 10, r.hp)
		offset += Snapshot.ENTITY_BYTES
	end

	-- The budget is the entire reason this format exists; assert it held.
	assert(buffer.len(b) <= Snapshot.MAX_BYTES, "Snapshot: encoded buffer exceeded MAX_BYTES")
	return b
end

local function readRecords(b: buffer): (number, boolean, { Record })
	local len = buffer.len(b)
	if len < Snapshot.HEADER_BYTES then
		error(`Snapshot.decode: buffer too short ({len} bytes, need at least {Snapshot.HEADER_BYTES})`, 3)
	end

	local tick = buffer.readu32(b, 0)
	local countAndFlags = buffer.readu8(b, 4)
	local count = bit32.band(countAndFlags, COUNT_MASK)
	local isKeyframe = bit32.band(countAndFlags, KEYFRAME_BIT) ~= 0

	local expected = Snapshot.byteSize(count)
	if len ~= expected then
		error(`Snapshot.decode: truncated packet — header claims {count} entities ({expected} bytes), got {len}`, 3)
	end

	local records: { Record } = table.create(count)
	local offset = Snapshot.HEADER_BYTES
	for i = 1, count do
		records[i] = {
			id = buffer.readu16(b, offset),
			x = buffer.readi16(b, offset + 2),
			y = buffer.readi16(b, offset + 4),
			z = buffer.readi16(b, offset + 6),
			yaw = buffer.readu8(b, offset + 8),
			state = buffer.readu8(b, offset + 9),
			hp = buffer.readu8(b, offset + 10),
		}
		offset += Snapshot.ENTITY_BYTES
	end

	return tick, isKeyframe, records
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Full snapshot (keyframe). Errors if the entity set exceeds capacity.
function Snapshot.encode(tick: number, entities: { Types.EntityView }, origin: Types.Vec3): buffer
	local records: { Record } = table.create(#entities)
	for i, view in entities do
		records[i] = Snapshot.toRecord(view, origin)
	end
	return writeRecords(tick, records, true)
end

function Snapshot.decode(b: buffer, origin: Types.Vec3): Snapshot
	local tick, isKeyframe, records = readRecords(b)
	local entities: { Types.EntityView } = table.create(#records)
	for i, r in records do
		entities[i] = Snapshot.fromRecord(r, origin)
	end
	return { tick = tick, isKeyframe = isKeyframe, entities = entities }
end

--- Delta against a baseline: only entities whose quantized record changed.
--- An entity absent from the baseline is treated as changed, so newly visible
--- entities are always carried.
function Snapshot.encodeDelta(
	tick: number,
	entities: { Types.EntityView },
	baseline: { Types.EntityView },
	origin: Types.Vec3
): buffer
	local baseById: { [number]: Record } = {}
	for _, view in baseline do
		local r = Snapshot.toRecord(view, origin)
		baseById[r.id] = r
	end

	local changed: { Record } = {}
	for _, view in entities do
		local r = Snapshot.toRecord(view, origin)
		local prev = baseById[r.id]
		if prev == nil or not Snapshot.recordsEqual(prev, r) then
			table.insert(changed, r)
		end
	end

	return writeRecords(tick, changed, false)
end

--- Merge a delta onto a baseline. Entities not mentioned keep their baseline
--- state; nothing is ever removed (see the note at the top of this file).
--- Output order is stable: baseline order first, then newly seen entities in
--- packet order, so a caller diffing successive results sees no spurious churn.
function Snapshot.applyDelta(baseline: { Types.EntityView }, b: buffer, origin: Types.Vec3): Snapshot
	local tick, isKeyframe, records = readRecords(b)

	local updates: { [number]: Types.EntityView } = {}
	local order: { number } = {}
	for _, r in records do
		local id = r.id
		if updates[id] == nil then
			table.insert(order, id)
		end
		updates[id] = Snapshot.fromRecord(r, origin)
	end

	local merged: { Types.EntityView } = {}
	local seen: { [number]: boolean } = {}
	for _, view in baseline do
		seen[view.id] = true
		local update = updates[view.id]
		merged[#merged + 1] = if update ~= nil then update else view
	end
	for _, id in order do
		if not seen[id] then
			merged[#merged + 1] = updates[id]
		end
	end

	return { tick = tick, isKeyframe = isKeyframe, entities = merged }
end

--- Whether tick N should be sent as a full keyframe.
function Snapshot.isKeyframeTick(tick: number): boolean
	return tick % Snapshot.KEYFRAME_INTERVAL == 0
end

return Snapshot
