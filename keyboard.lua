-- 初始化 UART
UART = UART or {}
UART.inputBuffer = UART.inputBuffer or {}

-- 功能键状态
local shift_pressed = false
local caps_lock_on = false
local ctrl_pressed = false
local alt_pressed = false

-- ✅ 终端输出映射表 { key_name -> 输出内容 }
-- 类型说明：
--   string: 直接输出该字符串的每个字节
--   table: {无Shift字符, 有Shift字符}，用于字母和符号
--   false: 状态切换键，不输出
local terminal_key_map = {
    -- ========== 状态切换键 ==========
    LSHIFT = false, RSHIFT = false,
    LSHIFT_RELEASE = false, RSHIFT_RELEASE = false,
    CAPSLOCK = false,
    LCTRL = false, RCTRL = false,
    LCTRL_RELEASE = false, RCTRL_RELEASE = false,
    LALT = false, RALT = false,
    LALT_RELEASE = false, RALT_RELEASE = false,
    LWIN = false,
    LWIN_RELEASE = false,

    -- ========== 控制字符 ==========
    ENTER = "\n",
    NUMPADENTER = "\n",
    BACKSPACE = "\127",  -- DEL (0x7F) 
    DEL = "\27[3~",
    TAB = "\t",
    ESC = "\27",
    SPACE = " ",

    -- ========== 方向键 ANSI 转义序列 ==========
    UP = "\27[A",      -- ← 等价于 function() return "\27[A" end
    DOWN = "\27[B",
    RIGHT = "\27[C",
    LEFT = "\27[D",

    -- ========== F1-F12 ANSI 序列 ==========
    F1 = "\27[11~", F2 = "\27[12~", F3 = "\27[13~", F4 = "\27[14~",
    F5 = "\27[15~", F6 = "\27[17~", F7 = "\27[18~", F8 = "\27[19~",
    F9 = "\27[20~", F10 = "\27[21~", F11 = "\27[23~", F12 = "\27[24~",

    -- ========== 数字键 ==========
    ["0"] = {"0", ")"},
    ["1"] = {"1", "!"},
    ["2"] = {"2", "@"},
    ["3"] = {"3", "#"},
    ["4"] = {"4", "$"},
    ["5"] = {"5", "%"},
    ["6"] = {"6", "^"},
    ["7"] = {"7", "&"},
    ["8"] = {"8", "*"},
    ["9"] = {"9", "("},

    -- ========== 符号键 ==========
    MINUS = {"-", "_"},
    EQUAL = {"=", "+"},
    LBRACKET = {"[", "{"},
    RBRACKET = {"]", "}"},
    BACKSLASH = {"\\", "|"},
    SEMICOLON = {";", ":"},
    QUOTE = {"'", "\""},
    COMMA = {",", "<"},
    PERIOD = {".", ">"},
    SLASH = {"/", "?"},
    BACKTICK = {"`", "~"}, 

    -- ========== 字母键 ==========
    A = {"a", "A"}, B = {"b", "B"}, C = {"c", "C"}, D = {"d", "D"}, E = {"e", "E"},
    F = {"f", "F"}, G = {"g", "G"}, H = {"h", "H"}, I = {"i", "I"}, J = {"j", "J"},
    K = {"k", "K"}, L = {"l", "L"}, M = {"m", "M"}, N = {"n", "N"}, O = {"o", "O"},
    P = {"p", "P"}, Q = {"q", "Q"}, R = {"r", "R"}, S = {"s", "S"}, T = {"t", "T"},
    U = {"u", "U"}, V = {"v", "V"}, W = {"w", "W"}, X = {"x", "X"}, Y = {"y", "Y"},
    Z = {"z", "Z"},
}

-- 注册按键事件
local function register_key(key)
    LuaAPI.global_register_trigger_event({ EVENT.UI_CUSTOM_EVENT, key }, function(event_name, actor, data)
        local role_id = data and data.role_id or "unknown"
        --print("Key pressed: " .. key .. " by role_id: " .. tostring(role_id))

        -- 处理状态切换键
        if key == "LSHIFT" or key == "RSHIFT" then
            shift_pressed = true
            --print("Shift " .. (shift_pressed and "ON" or "OFF"))
            return
        elseif key == "CAPSLOCK" then
            caps_lock_on = not caps_lock_on
            --print("Caps Lock " .. (caps_lock_on and "ON" or "OFF"))
            return
        elseif key == "LCTRL" or key == "RCTRL" then
            ctrl_pressed = true
            --print("Ctrl " .. (ctrl_pressed and "ON" or "OFF"))
            return
        elseif key == "LALT" or key == "RALT" then
            alt_pressed = true
            --print("Alt " .. (alt_pressed and "ON" or "OFF"))
            return
        elseif key == "LSHIFT_RELEASE" or key == "RSHIFT_RELEASE" then
            shift_pressed = false
            --print("Shift " .. (shift_pressed and "ON" or "OFF"))
            return
        elseif key == "LCTRL_RELEASE" or key == "RCTRL_RELEASE" then
            ctrl_pressed = false
            --print("Ctrl " .. (ctrl_pressed and "ON" or "OFF"))
            return
        elseif key == "LALT_RELEASE" or key == "RALT_RELEASE" then
            alt_pressed = false
            --print("Alt " .. (alt_pressed and "ON" or "OFF"))
            return
        elseif key == "LWIN" then
            -- Windows 键按下，忽略
            return
        elseif key == "LWIN_RELEASE" then
            -- Windows 键释放，忽略
            return
        end

        -- 处理 Ctrl + 字母组合
        if ctrl_pressed and key:match("^[A-Z]$") then
            local ctrl_code = string.byte(key:lower()) - 96
            UART.inputBuffer[#UART.inputBuffer + 1] = ctrl_code
            --print("Ctrl+" .. key .. " → ^" .. key:lower() .. " (0x" .. string.format("%02X", ctrl_code) .. ")")
            return
        end

        -- 获取映射
        local def = terminal_key_map[key]
        if def == nil then
            print("Warning: No mapping for key - " .. key)
            return
        end

        -- 不输出的键（状态键）
        if def == false then
            return
        end

        -- 处理 Shift/Caps 字符表
        if type(def) == "table" then
            local output_char
            if key:match("^[A-Z]$") then
                if (shift_pressed and not caps_lock_on) or (not shift_pressed and caps_lock_on) then
                    output_char = def[2]
                else
                    output_char = def[1]
                end
            else
                output_char = shift_pressed and def[2] or def[1]
            end
            UART.inputBuffer[#UART.inputBuffer + 1] = string.byte(output_char)
            --print("Output char: '" .. output_char .. "'")
            return
        end

        -- 处理字符串（包括转义序列如 \27[A）
        if type(def) == "string" then
            for i = 1, #def do
                UART.inputBuffer[#UART.inputBuffer + 1] = string.byte(def, i)
            end
            --print("Output: " .. def:gsub("%c", function(c)
            --    return string.format("<0x%02X>", string.byte(c))
            --end))
            return
        end
    end)
end

-- 自动注册所有键
for k in pairs(terminal_key_map) do
    register_key(k)
end

-- 重置函数
function reset_keyboard_state()
    shift_pressed = false
    caps_lock_on = false
    ctrl_pressed = false
    alt_pressed = false
    print("Keyboard state reset.")
end