--!strict
--[[ SHA-256 and HMAC-SHA256, in pure Luau.

	Needed for two things the telemetry pipeline cannot do without:

	  - **Signing ingest batches.** docs/04: HMAC-SHA256 over `timestamp + nonce
	    + body`. Roblox has no per-server identity primitive, so this is
	    defence in depth rather than real auth — but an unsigned endpoint on the
	    open internet is not a thing to ship either.
	  - **Pseudonymising player ids.** `pid = HMAC(userId, PLAYER_SALT)`, with
	    the salt held only by the backend. Analytics work across runs and the
	    raw Roblox user id never leaves the game server.

	Roblox provides no hashing primitive, so this is implemented from the FIPS
	180-4 description on `bit32`, which exists in both Roblox and Lune. It is
	tested against the published NIST and RFC 4231 vectors rather than against
	itself — a hash that is self-consistently wrong is the worst possible
	outcome, because every signature would verify locally and none would verify
	on the backend.

	Not constant-time. Nothing here compares secrets on the game server; the
	backend does that comparison, in Node, where `timingSafeEqual` exists.
]]

local Hmac = {}

local BLOCK_BYTES = 64

local K: { number } = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local INITIAL: { number } = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local function preprocess(message: string): string
	local length = #message
	-- 0x80, then zeros, then the 64-bit big-endian bit length.
	local padded = message .. "\128"
	local remainder = (length + 1) % BLOCK_BYTES
	local zeros = (56 - remainder) % BLOCK_BYTES
	padded ..= string.rep("\0", zeros)

	local bits = length * 8
	-- Lengths beyond 2^32 bits cannot occur here (batches are kilobytes), so
	-- the high word is written as zero rather than pretending to support it.
	padded ..= string.pack(">I4>I4", math.floor(bits / 4294967296), bits % 4294967296)
	return padded
end

--- Raw 32-byte digest.
function Hmac.sha256Bytes(message: string): string
	local h = table.clone(INITIAL)
	local padded = preprocess(message)
	local w: { number } = table.create(64, 0)

	for block = 1, #padded, BLOCK_BYTES do
		for i = 1, 16 do
			w[i] = string.unpack(">I4", padded, block + (i - 1) * 4)
		end
		for i = 17, 64 do
			local w15, w2 = w[i - 15], w[i - 2]
			local s0 = bit32.bxor(bit32.rrotate(w15, 7), bit32.rrotate(w15, 18), bit32.rshift(w15, 3))
			local s1 = bit32.bxor(bit32.rrotate(w2, 17), bit32.rrotate(w2, 19), bit32.rshift(w2, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
		end

		local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]

		for i = 1, 64 do
			local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
			local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
			local temp1 = (hh + s1 + ch + K[i] + w[i]) % 4294967296
			local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
			local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
			local temp2 = (s0 + maj) % 4294967296

			hh, g, f, e, d, c, b, a = g, f, e, (d + temp1) % 4294967296, c, b, a, (temp1 + temp2) % 4294967296
		end

		h[1] = (h[1] + a) % 4294967296
		h[2] = (h[2] + b) % 4294967296
		h[3] = (h[3] + c) % 4294967296
		h[4] = (h[4] + d) % 4294967296
		h[5] = (h[5] + e) % 4294967296
		h[6] = (h[6] + f) % 4294967296
		h[7] = (h[7] + g) % 4294967296
		h[8] = (h[8] + hh) % 4294967296
	end

	local out = {}
	for i = 1, 8 do
		out[i] = string.pack(">I4", h[i])
	end
	return table.concat(out)
end

local function toHex(bytes: string): string
	return (string.gsub(bytes, ".", function(char)
		return string.format("%02x", string.byte(char))
	end))
end

Hmac.toHex = toHex

--- Lowercase hex digest, which is what the wire format carries.
function Hmac.sha256(message: string): string
	return toHex(Hmac.sha256Bytes(message))
end

--- HMAC-SHA256 per RFC 2104. Keys longer than the block are hashed first;
--- shorter keys are zero-padded.
function Hmac.hmacBytes(key: string, message: string): string
	local block = key
	if #block > BLOCK_BYTES then
		block = Hmac.sha256Bytes(block)
	end
	block ..= string.rep("\0", BLOCK_BYTES - #block)

	local inner, outer = table.create(BLOCK_BYTES), table.create(BLOCK_BYTES)
	for i = 1, BLOCK_BYTES do
		local byte = string.byte(block, i)
		inner[i] = string.char(bit32.bxor(byte, 0x36))
		outer[i] = string.char(bit32.bxor(byte, 0x5c))
	end

	local innerHash = Hmac.sha256Bytes(table.concat(inner) .. message)
	return Hmac.sha256Bytes(table.concat(outer) .. innerHash)
end

function Hmac.hmac(key: string, message: string): string
	return toHex(Hmac.hmacBytes(key, message))
end

--- Pseudonymous, stable player id. Truncated to 16 hex characters: still 64
--- bits of collision resistance across a player base that will never approach
--- it, and short enough to be a comfortable database key.
function Hmac.pid(userId: number, salt: string): string
	return string.sub(Hmac.hmac(salt, `roblox:{math.floor(userId)}`), 1, 16)
end

--- The signature the backend recomputes: HMAC over timestamp, nonce and body,
--- joined by a character that cannot appear in the first two fields. Without a
--- separator, `("1", "23")` and `("12", "3")` would sign identically.
function Hmac.signRequest(secret: string, timestamp: number, nonce: string, body: string): string
	return Hmac.hmac(secret, `{math.floor(timestamp)}.{nonce}.{body}`)
end

return Hmac
