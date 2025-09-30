-- Base85 字符集
local base85_chars = [[!"v$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[w]^_`abcdefghijklmnopqrstu]]
local base85_map = {}
for i = 1, #base85_chars do
    base85_map[base85_chars:sub(i, i)] = i - 1
end

local base85={}

-- Base85 编码函数
base85.encode = function (data)
    local result = {}
    local len = #data

    -- 补齐到 4 的倍数
    local padding = math.tointeger((4 - len % 4) % 4)
    for i = 1, padding do
        data = data .. "\0"
    end

    -- 分组处理
    for i = 1, #data, 4 do
        -- 每 4 字节转为一个 32 位整数
        local num = 0
        for j = 0, 3 do
            num = num + string.byte(data,i + j) * math.tointeger(256^(3 - j))
 
        end
        if num == 0 then
            result[#result + 1] = "z"
        else
            -- 转换为 5 个 Base85 字符
            local chars = {}
            for j = 1, 5 do
                local remainder = math.tointeger(num % 85)  
                local halfnum1 = num>>1
                local halfnum2 = num-halfnum1
                local div=85
                local q1 = math.tointeger(halfnum1 // div)
                local q2 = math.tointeger(halfnum2 // div)
                local r1 = halfnum1 - q1 * div
                local r2 = halfnum2 - q2 * div
                num = q1+q2+math.tointeger((r1+r2)//div) 
                chars[6 - j] = string.sub(base85_chars,remainder + 1, remainder + 1) 
            
            end
            result[#result + 1] = table.concat(chars)
        end
    end

    -- 去掉多余的填充字符
    local encoded = table.concat(result)
    if padding > 0 then
        encoded = encoded:sub(1, #encoded - padding)
    end

    return encoded
end

-- Base85 解码函数
base85.decode = function(encoded)
       encoded = encoded:gsub("z", "!!!!!")
    local result = {}
    local len = #encoded

    -- 补齐到 5 的倍数
    local padding = (5 - len % 5) % 5
    for i = 1, padding do
        encoded = encoded .. "u" -- 'u' 对应 Base85 的 84
    end

    -- 分组处理
    for i = 1, #encoded, 5 do
        -- 每 5 个字符转为一个 32 位整数
        local num = 0
        for j = 0, 4 do
            local char = encoded:sub(i + j, i + j)
            if not base85_map[char] then
                print("Invalid Base85 character: " .. char:byte())
                return nil
            end
            assert(base85_map[char], "Invalid Base85 character: " .. char)
            num = num * 85 + math.tointeger(base85_map[char])
        end

        -- 转换为 4 字节
        local bytes = {}
        for j = 0, 3 do
            bytes[4 - j] = string.char(num % 256)
            local halfnum1 = num>>1
            local halfnum2 = num-halfnum1
            local div=256
            local q1 = math.tointeger(halfnum1 // div)
            local q2 = math.tointeger(halfnum2 // div)
            local r1 = halfnum1 - q1 * div
            local r2 = halfnum2 - q2 * div
            num = q1+q2+math.tointeger((r1+r2)//div)  
        end
        result[#result + 1] = table.concat(bytes)
    end

    -- 去掉多余的填充字节
    local decoded = table.concat(result)
    if padding > 0 then
        decoded = decoded:sub(1, #decoded - padding)
    end

    return decoded
end


return base85