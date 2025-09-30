local success = LuaAPI.enable_developer_mode()
LuaAPI.enable_experimental_feature(true)
local Zstd = Asset.Zstd

function readBinary(filename)
    local file = io.open(filename, "rb")
    if not file then return nil end
    local data = file:read("*all")
    file:close()
    return data
end

-- 使用
local bindata = readBinary("badapple.bin")
print(#bindata)
local compressed = Zstd.compress(bindata)
print(#compressed)
local output_file = io.open("badapple.zst", "wb")

output_file:write(compressed)
output_file:close()