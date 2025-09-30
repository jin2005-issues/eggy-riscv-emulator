local Image = require("Image")
local data1 = Image:sub(1, 800000)
local data2 = Image:sub(800001)
local file1 = io.open("Image_part1.lua", "w")
data1 = "return [=====[" .. data1 .. "]=====]"
file1:write(data1)
file1:close()

for i = 1, #data2, 100000 do
    local file2 = io.open("Image_part2_" .. math.floor((i - 1) / 100000 + 1) .. ".txt", "w")
    local part = data2:sub(i, i + 99999) 
    file2:write(part)
    file2:close()
end
print("Splitting completed.")
