DTB = {}
DTB.base = 0x1000
local Zstd = Asset.Zstd
local base85 = require("base85")
function DTB.load(filename)
	if filename ~= "" then
		local file = assert(io.open(filename, "rb"))
		DTB.dtb = file:read("*all")
		DTB.length = #DTB.dtb
		file:close()
		local out = Zstd.compress(DTB.dtb)
		local output_file = io.open("dtb.zst", "wb")

    	output_file:write(out)
	else
		local encodedData = require("dtb")
		local decodedData = base85.decode(encodedData)
		DTB.dtb = Zstd.decompress(decodedData)
		DTB.length = #DTB.dtb
	end

end

DTB.load("") -- need it loaded to register it into memory

function DTB.read(addr)
	return DTB.dtb:byte(addr + 1, addr + 1)
end

Memory.register(DTB.base, DTB.length, {
	read = function (addr)
		return DTB.read(addr)
	end,
	write = function (addr, byte)
		-- unreachable
	end,
	validRead = function ()
		return true -- all readable
	end,
	validWrite = function ()
		return false -- no
	end
})