-- VT100 终端模拟器（增强版：支持插入模式、完整删除、缓冲区切换）
local VT100 = {}

function VT100:new(screen_ui)
    local instance = {
        -- 屏幕缓冲区: 24行 x 80列，每个单元是 {char, fg, bg, bold, underline}
        screen = {},
        -- 光标位置（从1开始）
        cursor_x = 1,
        cursor_y = 1,
        -- 当前属性
        current_fg = 37,   -- 默认前景：白色
        current_bg = 40,   -- 默认背景：黑色
        bold = false,
        underline = false,
        blink_state = false,  -- 用于控制光标闪烁
        cursor_visible = true,  -- 光标显示状态
        -- 状态
        escape_sequence = false,
        escape_buffer = "",
        charset_graphic = false,  -- 是否启用 DEC 图形字符集
        insert_mode = false,      -- 插入模式
        screen_ui = screen_ui,
        -- 缓冲区切换支持
        in_alternate_screen = false,
        primary_screen = nil,
        primary_cursor_x = 1,
        primary_cursor_y = 1
    }

    -- 初始化主屏幕
    for y = 1, 24 do
        instance.screen[y] = {}
        for x = 1, 80 do
            instance.screen[y][x] = {
                char = " ",
                fg = 37,
                bg = 40,
                bold = false,
                underline = false
            }
        end
    end

    setmetatable(instance, { __index = VT100 })
    return instance
end

-- 重置当前属性到默认
function VT100:reset_attributes()
    self.current_fg = 37
    self.current_bg = 40
    self.bold = false
    self.underline = false
end

-- 写入一个字符到当前光标位置，并前移光标（自动换行）
function VT100:putchar(c)
    if self.cursor_y < 1 or self.cursor_y > 24 or self.cursor_x < 1 or self.cursor_x > 80 then
        return -- 安全保护
    end

    -- 如果是图形字符模式，转换字符
    if self.charset_graphic then
        local graphic_map = {
            ['`'] = '◆', ['a'] = '▒', ['b'] = '␉', ['c'] = '␌', ['d'] = '␍', ['e'] = '␊',
            ['f'] = '°', ['g'] = '±', ['h'] = '␤', ['i'] = '␋', ['j'] = '┘', ['k'] = '┐',
            ['l'] = '┌', ['m'] = '└', ['n'] = '┼', ['o'] = '⎺', ['p'] = '⎻', ['q'] = '─',
            ['r'] = '⎼', ['s'] = '⎽', ['t'] = '├', ['u'] = '┤', ['v'] = '┴', ['w'] = '┬',
            ['x'] = '│', ['y'] = '≤', ['z'] = '≥', ['{'] = 'π', ['|'] = '≠', ['}'] = '£',
            ['~'] = '·'
        }
        c = graphic_map[c] or c
    end

    -- 插入模式：当前字符及之后右移
    if self.insert_mode and self.cursor_x < 80 then
        for x = 80, self.cursor_x + 1, -1 do
            self.screen[self.cursor_y][x] = self.screen[self.cursor_y][x - 1]
        end
    end

    -- 写入字符和当前属性
    self.screen[self.cursor_y][self.cursor_x] = {
        char = c,
        fg = self.current_fg,
        bg = self.current_bg,
        bold = self.bold,
        underline = self.underline
    }

    -- 光标右移
    self.cursor_x = self.cursor_x + 1

    -- 自动换行
    if self.cursor_x > 80 then
        self.cursor_x = 1
        if self.cursor_y < 24 then
            self.cursor_y = self.cursor_y + 1
        else
            self:scroll_up()
        end
    end
end

-- 向上滚动一行（深拷贝避免引用污染）
function VT100:scroll_up()
    for y = 1, 23 do
        self.screen[y] = {}
        for x = 1, 80 do
            local src = self.screen[y + 1][x]
            self.screen[y][x] = {
                char = src.char,
                fg = src.fg,
                bg = src.bg,
                bold = src.bold,
                underline = src.underline
            }
        end
    end
    self.screen[24] = {}
    for x = 1, 80 do
        self.screen[24][x] = {
            char = " ",
            fg = self.current_fg,
            bg = self.current_bg,
            bold = self.bold,
            underline = self.underline
        }
    end
end

-- 处理控制字符
function VT100:handle_control_char(c)
    if c == "\n" then
        self.cursor_x = 1
        if self.cursor_y < 24 then
            self.cursor_y = self.cursor_y + 1
        else
            self:scroll_up()
        end
    elseif c == "\r" then
        self.cursor_x = 1
    elseif c == "\b" then
        if self.cursor_x > 1 then
            self.cursor_x = self.cursor_x - 1
        end
    elseif c == "\t" then
        local next_tab = ((self.cursor_x + 7) // 8) * 8 + 1
        self.cursor_x = math.min(next_tab, 81)
        if self.cursor_x > 80 then
            self.cursor_x = 1
            if self.cursor_y < 24 then
                self.cursor_y = self.cursor_y + 1
            else
                self:scroll_up()
            end
        end
    elseif c == "\x07" then
        -- BEL - 忽略响铃
    end
end

-- 解析 CSI 序列（ESC [ ...）
function VT100:parse_csi(params, final_char)
    local nums = {}
    for param in params:gmatch("[^;]+") do
        table.insert(nums, math.tointeger(param) or 0)
    end

    local function get_param(i, default)
        return nums[i] or default
    end

    -- DEC 私有模式（以 ? 开头）
    if params:sub(1, 1) == "?" then
        local private_param = params:sub(2)  -- 去掉 ?
        if final_char == "h" then
            if private_param == "1049" then
                self:switch_to_alternate_screen()
            elseif private_param == "25" then
                self.cursor_visible = true
                -- 可选：显示光标（暂不实现视觉，但可记录状态）
            elseif private_param == "1" then
                
                -- 应用光标键模式（忽略）
            end
        elseif final_char == "l" then
            if private_param == "1049" then
                self:switch_to_primary_screen()
            elseif private_param == "25" then
                self.cursor_visible = false
                -- 可选：隐藏光标
            elseif private_param == "1" then
                -- 正常光标键模式（忽略）
            end
        end
        return
    end

    -- 标准 CSI 序列
    if final_char == "H" or final_char == "f" then
        -- CUP / HVP: 设置光标位置
        local row = get_param(1, 1)
        local col = get_param(2, 1)
        self.cursor_y = math.max(1, math.min(24, row))
        self.cursor_x = math.max(1, math.min(80, col))
    elseif final_char == "A" then
        -- CUU: 光标上移
        self.cursor_y = math.max(1, self.cursor_y - get_param(1, 1))
    elseif final_char == "B" then
        -- CUD: 光标下移
        self.cursor_y = math.min(24, self.cursor_y + get_param(1, 1))
    elseif final_char == "C" then
        -- CUF: 光标右移
        self.cursor_x = math.min(80, self.cursor_x + get_param(1, 1))
    elseif final_char == "D" then
        -- CUB: 光标左移
        self.cursor_x = math.max(1, self.cursor_x - get_param(1, 1))
    elseif final_char == "J" then
        -- ED: 清除屏幕
        local mode = get_param(1, 0)
        if mode == 0 then
            -- 清除光标到屏幕末尾
            for y = self.cursor_y, 24 do
                local start_x = (y == self.cursor_y) and self.cursor_x or 1
                for x = start_x, 80 do
                    self.screen[y][x] = {
                        char = " ",
                        fg = self.current_fg,
                        bg = self.current_bg,
                        bold = self.bold,
                        underline = self.underline
                    }
                end
            end
        elseif mode == 1 then
            -- 清除屏幕开始到光标
            for y = 1, self.cursor_y do
                local end_x = (y == self.cursor_y) and self.cursor_x or 80
                for x = 1, end_x do
                    self.screen[y][x] = {
                        char = " ",
                        fg = self.current_fg,
                        bg = self.current_bg,
                        bold = self.bold,
                        underline = self.underline
                    }
                end
            end
        elseif mode == 2 then
            -- 清全屏
            for y = 1, 24 do
                for x = 1, 80 do
                    self.screen[y][x] = {
                        char = " ",
                        fg = self.current_fg,
                        bg = self.current_bg,
                        bold = self.bold,
                        underline = self.underline
                    }
                end
            end
        end
    elseif final_char == "K" then
        -- EL: 清除行
        local mode = get_param(1, 0)
        if mode == 0 then
            -- 清除光标到行尾
            for x = self.cursor_x, 80 do
                self.screen[self.cursor_y][x] = {
                    char = " ",
                    fg = self.current_fg,
                    bg = self.current_bg,
                    bold = self.bold,
                    underline = self.underline
                }
            end
        elseif mode == 1 then
            -- 清除行首到光标
            for x = 1, self.cursor_x do
                self.screen[self.cursor_y][x] = {
                    char = " ",
                    fg = self.current_fg,
                    bg = self.current_bg,
                    bold = self.bold,
                    underline = self.underline
                }
            end
        elseif mode == 2 then
            -- 清除整行
            for x = 1, 80 do
                self.screen[self.cursor_y][x] = {
                    char = " ",
                    fg = self.current_fg,
                    bg = self.current_bg,
                    bold = self.bold,
                    underline = self.underline
                }
            end
        end
    elseif final_char == "m" then
        if #nums == 0 then
            nums = {0} -- 没有参数等同于重置
        end
        -- SGR: 设置图形属性
        for _, n in ipairs(nums) do
            if n == 0 then
                self:reset_attributes()
            elseif n == 1 then
                self.bold = true
            elseif n == 4 then
                self.underline = true
            elseif n >= 30 and n <= 37 then
                self.current_fg = n
            elseif n >= 40 and n <= 47 then
                self.current_bg = n
            end
        end
    -- Delete 键
    elseif final_char == "~" and get_param(1, 0) == 3 then
        if self.cursor_x >= 1 and self.cursor_x < 80 then
            for x = self.cursor_x, 79 do
                self.screen[self.cursor_y][x] = self.screen[self.cursor_y][x + 1]
            end
            self.screen[self.cursor_y][80] = {
                char = " ",
                fg = self.current_fg,
                bg = self.current_bg,
                bold = self.bold,
                underline = self.underline
            }
        elseif self.cursor_x == 80 then
            self.screen[self.cursor_y][80] = {
                char = " ",
                fg = self.current_fg,
                bg = self.current_bg,
                bold = self.bold,
                underline = self.underline
            }
        end
    -- Insert 键
    elseif final_char == "~" and get_param(1, 0) == 2 then
        self.insert_mode = not self.insert_mode
    -- Home 键
    elseif final_char == "~" and get_param(1, 0) == 1 then
        self.cursor_x = 1
    -- End 键
    elseif final_char == "~" and get_param(1, 0) == 4 then
        self.cursor_x = 80
    end
end

-- 解析 ESC 非 CSI 序列
function VT100:parse_esc(seq)
    if seq == "(0" then
        self.charset_graphic = true
    elseif seq == "(B" then
        self.charset_graphic = false
    elseif seq == "7" then
        -- 保存光标（暂不实现）
    elseif seq == "8" then
        -- 恢复光标（暂不实现）
    elseif seq == "=" then
        -- 小键盘应用模式（忽略）
    elseif seq == ">" then
        -- 小键盘数字模式（忽略）
    end
end

-- 主要写入函数：解析字符串并更新屏幕
function VT100:write(s)
    for i = 1, #s do
        local c = s:sub(i, i)

        if self.escape_sequence then
            self.escape_buffer = self.escape_buffer .. c

            if #self.escape_buffer == 1 then
                if c == "[" then
                    -- CSI 继续
                else
                    self:parse_esc(self.escape_buffer)
                    self.escape_sequence = false
                    self.escape_buffer = ""
                end
            elseif c:match("[%a@]") then
                local buf = self.escape_buffer
                self.escape_sequence = false
                self.escape_buffer = ""

                if buf:sub(1, 1) == "[" then
                    local params = buf:sub(2, -2)
                    local final = buf:sub(-1)
                    self:parse_csi(params, final)
                else
                    self:parse_esc(buf)
                end
            end
        else
            if c == "\x1b" then
                self.escape_sequence = true
                self.escape_buffer = ""
            elseif c:match("[%c]") then
                self:handle_control_char(c)
            else
                self:putchar(c)
            end
        end
    end
end

-- 切换到备用屏幕缓冲区
function VT100:switch_to_alternate_screen()
    if self.in_alternate_screen then return end

    -- 保存主屏幕状态
    self.primary_screen = {}
    for y = 1, 24 do
        self.primary_screen[y] = {}
        for x = 1, 80 do
            local cell = self.screen[y][x]
            self.primary_screen[y][x] = {
                char = cell.char,
                fg = cell.fg,
                bg = cell.bg,
                bold = cell.bold,
                underline = cell.underline
            }
        end
    end
    self.primary_cursor_x = self.cursor_x
    self.primary_cursor_y = self.cursor_y

    -- 清空为备用屏幕（初始空白）
    for y = 1, 24 do
        for x = 1, 80 do
            self.screen[y][x] = {
                char = " ",
                fg = self.current_fg,
                bg = self.current_bg,
                bold = self.bold,
                underline = self.underline
            }
        end
    end
    self.cursor_x = 1
    self.cursor_y = 1

    self.in_alternate_screen = true
end

-- 切换回主屏幕缓冲区
function VT100:switch_to_primary_screen()
    if not self.in_alternate_screen or not self.primary_screen then return end

    -- 恢复主屏幕内容
    for y = 1, 24 do
        for x = 1, 80 do
            local cell = self.primary_screen[y][x]
            self.screen[y][x] = {
                char = cell.char,
                fg = cell.fg,
                bg = cell.bg,
                bold = cell.bold,
                underline = cell.underline
            }
        end
    end
    self.cursor_x = self.primary_cursor_x
    self.cursor_y = self.primary_cursor_y

    self.in_alternate_screen = false
    self.primary_screen = nil  -- 释放内存
end

-- 渲染为自定义字体控制码格式
function VT100:render()
    local output = ""
    local ansi_to_rgb = {
        [30] = "000000", [31] = "FF0000", [32] = "00FF00", [33] = "FFFF00",
        [34] = "0000FF", [35] = "FF00FF", [36] = "00FFFF", [37] = "FFFFFF",
        [90] = "808080", [91] = "FF5555", [92] = "55FF55", [93] = "FFFF55",
        [94] = "5555FF", [95] = "FF55FF", [96] = "55FFFF", [97] = "FFFFFF",
    }

    for y = 1, 24 do
        local line = {}
        local last_attr = nil

        for x = 1, 80 do
            local cell = self.screen[y][x]

            local attr_str = ""
            local parts = {}

            if cell.fg and cell.fg ~= 37 then
                local color = ansi_to_rgb[cell.fg] or "FFFFFF"
                table.insert(parts, "c:" .. color)
            end

            if cell.bold then
                table.insert(parts, "O:1")
            end

            if cell.underline then
                local color = ansi_to_rgb[cell.fg] or "FFFFFF"
                table.insert(parts, "u:" .. color)
            elseif self.cursor_visible and y == self.cursor_y and x == self.cursor_x and self.blink_state then
                local cursor_color = ansi_to_rgb[cell.fg] or "FFFFFF"
                table.insert(parts, "u:" .. cursor_color)
            end

            if #parts > 0 then
                attr_str = "#f(" .. table.concat(parts, "|") .. ")"
            else
                attr_str = "#l"
            end

            if attr_str ~= last_attr then
                table.insert(line, attr_str)
                last_attr = attr_str
            end
            if self.cursor_visible and cell.char == " " and (x == self.cursor_x and y == self.cursor_y and self.blink_state) then
                table.insert(line, "_")  -- 光标位置显示下划线
            else
                table.insert(line, cell.char)
            end
        end
 
        output = output .. table.concat(line) .. "#r"
    end

    local roles = GameAPI.get_all_valid_roles()
    for _, role in ipairs(roles) do
        role.set_label_text(self.screen_ui, output)
    end
end

-- 切换光标闪烁状态
function VT100:toggle_cursor_blink()
    self.blink_state = not self.blink_state
end

return VT100