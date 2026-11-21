#!/usr/bin/lua
-- dnsprobe.lua PORT [HOST] : exit 0 when a UDP DNS server answers, 1 on timeout
-- The name "localhost" is answered by AdGuardHome from its hosts file, so the
-- probe never sends a query upstream (a probe to a normal name would be
-- forwarded through SmartDNS/PassWall and cost CPU).
local nixio = require("nixio")
local port = tonumber(arg[1]) or 3053
local host = arg[2] or "127.0.0.1"

local function u16(n)
	return string.char(math.floor(n / 256) % 256, n % 256)
end

local s = nixio.socket("inet", "dgram")
if not s then os.exit(2) end
s:setopt("socket", "rcvtimeo", 800)

local id = 0x1234
local q = u16(id) .. u16(0x0100) .. u16(1) .. u16(0) .. u16(0) .. u16(0)
	.. string.char(9) .. "localhost" .. string.char(0)
	.. u16(1) .. u16(1)

if not s:sendto(q, host, port) then os.exit(2) end
local data = s:recv(512)
if data and #data >= 12 and (data:byte(1) * 256 + data:byte(2)) == id then
	os.exit(0)
end
os.exit(1)
