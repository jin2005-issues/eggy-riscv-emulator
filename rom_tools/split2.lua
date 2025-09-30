--get argv
local args = {...}
local file = args[1]
if not file then
    print("Usage: lua split2.lua <filename>")
    os.exit(1)
end
--read file
local f = io.open(file, "r")
if not f then
    print("Error: Cannot open file " .. file)
    os.exit(1)
end
local data = f:read("*a")
f:close()
for i = 1, #data, 30000 do
    local part = data:sub(i, i + 29999) 
    local part_file = io.open(file .. "_part" .. math.floor((i - 1) / 30000 + 1) .. ".txt", "w")
    part_file:write(part)
    part_file:close()
end
print("Splitting completed.")