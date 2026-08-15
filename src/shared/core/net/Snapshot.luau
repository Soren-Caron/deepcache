--!strict
--[[ M1-2 / M1-3. Binary snapshot encode/decode with delta compression.

	Hard 900-byte budget: UnreliableRemoteEvent silently drops payloads over
	~1000 bytes. Do not raise MAX_BYTES. See docs/03-NETCODE.md.
]]

local Types = require("../Types")

export type Snapshot = {
	tick: number,
	entities: { Types.EntityView },
}

local Snapshot = {}

Snapshot.MAX_BYTES = 900
Snapshot.HEADER_BYTES = 5
Snapshot.ENTITY_BYTES = 11
Snapshot.KEYFRAME_INTERVAL = 20

--- Full snapshot. Asserts if the encoded result would exceed MAX_BYTES.
function Snapshot.encode(tick: number, entities: { Types.EntityView }, origin: Types.Vec3): buffer
	error("unimplemented: Snapshot.encode (M1-2)")
end

function Snapshot.decode(b: buffer, origin: Types.Vec3): Snapshot
	error("unimplemented: Snapshot.decode (M1-2)")
end

--- Delta against a previously acknowledged keyframe.
function Snapshot.encodeDelta(
	tick: number,
	entities: { Types.EntityView },
	baseline: { Types.EntityView },
	origin: Types.Vec3
): buffer
	error("unimplemented: Snapshot.encodeDelta (M1-3)")
end

function Snapshot.applyDelta(baseline: { Types.EntityView }, b: buffer, origin: Types.Vec3): Snapshot
	error("unimplemented: Snapshot.applyDelta (M1-3)")
end

--- How many entities fit in one packet. Used by interest management.
function Snapshot.capacity(): number
	return math.floor((Snapshot.MAX_BYTES - Snapshot.HEADER_BYTES) / Snapshot.ENTITY_BYTES)
end

return Snapshot
