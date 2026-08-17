--!strict
--[[ SHA-256 and HMAC-SHA256.

	Checked against the published NIST and RFC 4231 vectors, never against
	itself. A hash that is self-consistently wrong is the worst outcome
	available: every signature would verify locally and none would verify on
	the backend, and the failure would look like a network problem.
]]

local t = require("./framework")
local expect = t.expect

local Hmac = require("../src/shared/core/telemetry/Hmac")

--------------------------------------------------------------------------------

t.describe("SHA-256 against NIST vectors", function()
	t.it("hashes the empty string", function()
		expect(Hmac.sha256("")).toEqual("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	end)

	t.it("hashes abc", function()
		expect(Hmac.sha256("abc")).toEqual("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	end)

	t.it("hashes a 56-byte message that forces a second block", function()
		-- 448 bits: exactly the point where padding no longer fits in the block.
		expect(Hmac.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).toEqual(
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
		)
	end)

	t.it("hashes a 112-byte message spanning three blocks", function()
		expect(
			Hmac.sha256(
				"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
					.. "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
			)
		).toEqual("cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
	end)

	t.it("hashes a million 'a' characters", function()
		-- The long vector: catches length-encoding and block-count bugs that
		-- short inputs cannot reach.
		expect(Hmac.sha256(string.rep("a", 1000000))).toEqual(
			"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
		)
	end)

	t.it("hashes exactly one block", function()
		-- 64 bytes: padding spills into a whole extra block. Not a published
		-- vector — cross-checked against .NET System.Security.Cryptography.
		expect(Hmac.sha256(string.rep("x", 64))).toEqual(
			"7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c"
		)
	end)

	t.it("returns 32 raw bytes and 64 hex characters", function()
		expect(#Hmac.sha256Bytes("anything")).toEqual(32)
		expect(#Hmac.sha256("anything")).toEqual(64)
	end)

	t.it("handles bytes outside ASCII", function()
		-- Payloads are JSON, which can carry any UTF-8 byte.
		expect(#Hmac.sha256("\0\1\255\254 caf\195\169")).toEqual(64)
		expect(Hmac.sha256("\0")).toEqual("6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
	end)
end)

t.describe("HMAC-SHA256 against RFC 4231", function()
	t.it("case 1: 20-byte key", function()
		expect(Hmac.hmac(string.rep("\11", 20), "Hi There")).toEqual(
			"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
		)
	end)

	t.it("case 2: short key, longer message", function()
		expect(Hmac.hmac("Jefe", "what do ya want for nothing?")).toEqual(
			"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
		)
	end)

	t.it("case 3: 20-byte key, 50 bytes of 0xdd", function()
		expect(Hmac.hmac(string.rep("\170", 20), string.rep("\221", 50))).toEqual(
			"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
		)
	end)

	t.it("case 6: key longer than the block, which must be hashed first", function()
		expect(
			Hmac.hmac(string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First")
		).toEqual("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
	end)

	t.it("case 7: oversized key and oversized message", function()
		expect(
			Hmac.hmac(
				string.rep("\170", 131),
				"This is a test using a larger than block-size key and a larger "
					.. "than block-size data. The key needs to be hashed before being used"
					.. " by the HMAC algorithm."
			)
		).toEqual("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
	end)

	t.it("agrees with .NET HMACSHA256 on an arbitrary pair", function()
		-- A second independent implementation, since the RFC cases all use
		-- repeated-byte keys and this one does not.
		expect(Hmac.hmac("key", "message")).toEqual(
			"6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a"
		)
	end)

	t.it("differs from a plain hash of key concatenated with message", function()
		-- The classic mistake. If these ever match, the construction is wrong.
		expect(Hmac.hmac("key", "message")).never().toEqual(Hmac.sha256("key" .. "message"))
	end)
end)

t.describe("Hmac.pid", function()
	t.it("is stable for a user and salt", function()
		expect(Hmac.pid(9207276831, "salt-a")).toEqual(Hmac.pid(9207276831, "salt-a"))
	end)

	t.it("changes with the user and with the salt", function()
		expect(Hmac.pid(1, "salt-a")).never().toEqual(Hmac.pid(2, "salt-a"))
		-- Rotating the salt must invalidate every previous pid, or rotation is
		-- not a mitigation.
		expect(Hmac.pid(1, "salt-a")).never().toEqual(Hmac.pid(1, "salt-b"))
	end)

	t.it("does not leak the user id", function()
		local pid = Hmac.pid(9207276831, "secret-salt")
		expect(#pid).toEqual(16)
		expect(string.find(pid, "9207276831", 1, true)).toBeNil()
		expect(string.match(pid, "^[0-9a-f]+$")).never().toBeNil()
	end)

	t.it("does not collide across a realistic id range", function()
		local seen: { [string]: boolean } = {}
		for userId = 1, 5000 do
			local pid = Hmac.pid(userId * 7919, "salt")
			expect(seen[pid]).toBeFalsy()
			seen[pid] = true
		end
	end)
end)

t.describe("Hmac.signRequest", function()
	t.it("is stable for identical inputs", function()
		expect(Hmac.signRequest("s", 1000, "abc", "{}")).toEqual(Hmac.signRequest("s", 1000, "abc", "{}"))
	end)

	t.it("changes when any component changes", function()
		local base = Hmac.signRequest("s", 1000, "abc", "{}")
		expect(Hmac.signRequest("s2", 1000, "abc", "{}")).never().toEqual(base)
		expect(Hmac.signRequest("s", 1001, "abc", "{}")).never().toEqual(base)
		expect(Hmac.signRequest("s", 1000, "abd", "{}")).never().toEqual(base)
		expect(Hmac.signRequest("s", 1000, "abc", "{ }")).never().toEqual(base)
	end)

	t.it("cannot be confused by shifting a boundary between fields", function()
		-- Without a separator, (ts=1, nonce="23") and (ts=12, nonce="3") sign
		-- the same bytes, and a replay could move the boundary freely.
		expect(Hmac.signRequest("s", 1, "23", "body")).never().toEqual(Hmac.signRequest("s", 12, "3", "body"))
	end)
end)
