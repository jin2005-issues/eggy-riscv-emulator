require("riscv.helper")
require("riscv.memory")
require("riscv.uart")
require("riscv.ram")
require("riscv.dtb")
require("riscv.clint")
require("riscv.csrs")
require("riscv.trap")
local Zstd = Asset.Zstd
local base85 = require("base85")

local Core = {}
local filename = ""
if filename ~= "" then
    local file = assert(io.open(filename, "rb"))

    local data = file:read("*all")
    file:close()

    -- write it into ram
    for i = 1, #data do
        Ram.set(i - 1, data:byte(i, i))
    end


    local compressed = Zstd.compress(data)
    local output_file = io.open("Image.zst", "wb")

    output_file:write(compressed)
else
    ---move to main
end

---@param inst integer
---@return integer
local function b_type_imm(inst)
    local imm_12 = (inst & 0x80000000) >> 19
    local imm_11 = (inst & 0x80) << 4
    local imm_10_5 = (inst & 0x7E000000) >> 20
    local imm_4_1 = (inst & 0xF00) >> 7
    return imm_12 | imm_11 | imm_10_5 | imm_4_1
end

---@param inst integer
---@return integer
local function s_type_imm(inst)
    local imm_11_5 = (inst & 0xFE000000) >> 20
    local imm_4_0 = (inst & 0xF80) >> 7
    return imm_11_5 | imm_4_0
end

local Hart = {}
Hart.pc = 0x80000000
Hart.mode = Mode.Machine
Trap.setHart(Hart)

local RegX_mt = {
    __index = function(table, key)
        return rawget(table, key) or 0
    end,

    __newindex = function(table, key, value)
        if key ~= 0 then
            rawset(table, key, value)
        end
    end
}

local RegX = setmetatable({}, RegX_mt)

for i = 0, 31 do
    RegX[i] = 0
end
RegX[10] = 0      -- a0
RegX[11] = 0x1000 -- a1


-- Localize commonly used functions
local num_add = Num.add
local num_sub = Num.sub
local num_sext = Num.sext
local num_lshift = Num.lshift
local num_rshift = Num.rshift
local num_bxor = Num.bxor
local num_bor = Num.bor
local num_band = Num.band
local num_clear = Num.clear
local num_multiply = Num.multiply
local num_signed = Num.signed
local num_isneg = Num.isneg
local trap_raise = Trap.raise
local memory_read = Memory.read
local memory_write = Memory.write
local memory_validWrite = Memory.validWrite
local memory_validRead = Memory.validRead
local csrs_read = CSRs.read
local csrs_write = CSRs.write

-- OP-IMM instructions lookup table
local op_imm_handlers = {
    [0] = function(inst, rd, rs1, immediate)
        RegX[rd] = (RegX[rs1] + immediate) & 0xFFFFFFFF
    end,
    [2] = function(inst, rd, rs1, immediate)
        local immv
        if immediate >= 0x00008000 then
            immv = immediate - 0x10000
        else
            immv = immediate
        end
        local rs1v
        if RegX[rs1] >= 0x80000000 then
            rs1v = RegX[rs1] - 0x100000000
        else
            rs1v = RegX[rs1]
        end
        RegX[rd] = (rs1v < immv) and 1 or 0
    end,
    [3] = function(inst, rd, rs1, immediate)
        RegX[rd] = (RegX[rs1] < immediate) and 1 or 0
    end,
    [4] = function(inst, rd, rs1, immediate)
        RegX[rd] = (RegX[rs1] ~ immediate) & 0xFFFFFFFF
    end,
    [6] = function(inst, rd, rs1, immediate)
        RegX[rd] = (RegX[rs1]| immediate) & 0xFFFFFFFF
    end,
    [7] = function(inst, rd, rs1, immediate)
        RegX[rd] = (RegX[rs1] & immediate) & 0xFFFFFFFF
    end,
    [1] = function(inst, rd, rs1, immediate)
        local shift_amount = (inst >> 20) & 0x1F
        RegX[rd] = (RegX[rs1] << shift_amount) & 0xFFFFFFFF
    end,
    [5] = function(inst, rd, rs1, immediate)
        local shift_amount = (inst >> 20) & 0x1F
        if (inst & 0x40000000) ~= 0 then -- SRAI
            local rs1v
            if RegX[rs1] >= 0x80000000 then
                rs1v = RegX[rs1] - 0x100000000
            else
                rs1v = RegX[rs1]
            end
            RegX[rd] = rs1v >> shift_amount & 0xFFFFFFFF
        else -- SRLI
            RegX[rd] = (RegX[rs1] & 0xFFFFFFFF) >> shift_amount
        end
    end
}

-- OP instructions lookup table (without M extension)
local op_handlers_basic = {
    [0] = function(rs1, rs2, rd, funct7)
        if funct7 == 0 then      -- ADD
            RegX[rd] = num_add(RegX[rs1], RegX[rs2])
        elseif funct7 == 32 then -- SUB
            RegX[rd] = num_sub(RegX[rs1], RegX[rs2])
        end
    end,
    [1] = function(rs1, rs2, rd, funct7)
        RegX[rd] = num_lshift(RegX[rs1], RegX[rs2] % 32)
    end,
    [2] = function(rs1, rs2, rd, funct7)
        local signeda = num_signed(RegX[rs1], 32)
        local signedb = num_signed(RegX[rs2], 32)
        RegX[rd] = (signeda < signedb) and 1 or 0
    end,
    [3] = function(rs1, rs2, rd, funct7)
        RegX[rd] = (RegX[rs1] < RegX[rs2]) and 1 or 0
    end,
    [4] = function(rs1, rs2, rd, funct7)
        RegX[rd] = num_bxor(RegX[rs1], RegX[rs2])
    end,
    [5] = function(rs1, rs2, rd, funct7)
        if funct7 == 0 then      -- SRL
            RegX[rd] = num_rshift(RegX[rs1], RegX[rs2] % 32)
        elseif funct7 == 32 then -- SRA
            local a = RegX[rs1]
            local b = RegX[rs2] % 32
            local is_signed = num_isneg(a)
            local newval = num_rshift(a, b)
            if is_signed then
                local tval = (1 << b) - 1
                tval = num_lshift(tval, 32 - b)
                newval = newval + tval
            end
            RegX[rd] = newval
        end
    end,
    [6] = function(rs1, rs2, rd)
        RegX[rd] = num_bor(RegX[rs1], RegX[rs2])
    end,
    [7] = function(rs1, rs2, rd, funct7)
        RegX[rd] = num_band(RegX[rs1], RegX[rs2])
    end
}

-- M extension handlers
local m_extension_handlers = {
    [0] = function(rs1, rs2, rd) -- MUL
        local lo, hi = num_multiply(RegX[rs1], RegX[rs2])
        RegX[rd] = lo
    end,
    [1] = function(rs1, rs2, rd) -- MULH
        local rs1v, rs2v = RegX[rs1], RegX[rs2]
        local lo, hi = num_multiply(rs1v, rs2v)
        local newhi = hi
        if num_isneg(rs1v) then
            newhi = newhi - rs2v
        end
        if num_isneg(rs2v) then
            newhi = newhi - rs1v
        end
        newhi = newhi % (2 ^ 32)
        RegX[rd] = newhi
    end,
    [2] = function(rs1, rs2, rd) -- MULHSU
        local rs1v, rs2v = RegX[rs1], RegX[rs2]
        local lo, hi = num_multiply(rs1v, rs2v)
        local newhi = hi
        if num_isneg(rs1v) then
            newhi = newhi - rs2v
        end
        newhi = newhi % (2 ^ 32)
        RegX[rd] = newhi
    end,
    [3] = function(rs1, rs2, rd) -- MULHU
        local lo, hi = num_multiply(RegX[rs1], RegX[rs2])
        RegX[rd] = hi
    end,
    [4] = function(rs1, rs2, rd) -- DIV
        local rs1v, rs2v = RegX[rs1], RegX[rs2]
        local srs1v, srs2v = num_signed(rs1v, 32), num_signed(rs2v, 32)
        local val
        if rs1v == 2 ^ 31 and rs2v == 2 ^ 32 - 1 then -- overflow case
            val = rs1v
        elseif rs2v == 0 then
            val = 2 ^ 32 - 1 -- -1
        else
            val = srs1v / srs2v
            if val >= 0 then
                val = math.floor(val)
            else
                val = math.ceil(val)
            end
            val = math.tointeger(val)
            if val < 0 then
                val = val + 2 ^ 32
            end
        end
        RegX[rd] = val
    end,
    [5] = function(rs1, rs2, rd) -- DIVU
        local rs1v, rs2v = RegX[rs1], RegX[rs2]
        local val = rs1v // rs2v
        if rs2v == 0 then
            val = 2 ^ 32 - 1
        end
        RegX[rd] = val
    end,
    [6] = function(rs1, rs2, rd) -- REM
        local rs1v, rs2v = RegX[rs1], RegX[rs2]
        local srs1v, srs2v = num_signed(rs1v, 32), num_signed(rs2v, 32)
        local val
        if rs1v == 2 ^ 31 and rs2v == 2 ^ 32 - 1 then -- overflow case
            val = 0
        elseif rs2v == 0 then
            val = rs1v
        else
            local div = srs1v / srs2v
            if div >= 0 then
                div = math.floor(div)
            else
                div = math.ceil(div)
            end
            div = math.tointeger(div)
            local r = srs1v - div * srs2v
            if r < 0 then
                r = r + 2 ^ 32
            end
            val = r
        end
        RegX[rd] = val
    end,
    [7] = function(rs1, rs2, rd) -- REMU
        local rs1v, rs2v = RegX[rs1], RegX[rs2]
        local val = rs1v % rs2v
        if rs2v == 0 then
            val = rs1v
        end
        RegX[rd] = val
    end
}

-- Load instructions lookup table
local load_handlers = {
    [0] = function(rd, rs1, imm) -- LB
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local value = memory_read(addr, 1)
        if value then
            RegX[rd] = num_sext(value, 8)
        else
            trap_raise(5, addr) -- 5 = Load Access Fault
        end
    end,
    [1] = function(rd, rs1, imm) -- LH
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local value = memory_read(addr, 2)
        if value then
            RegX[rd] = num_sext(value, 16)
        else
            trap_raise(5, addr)
        end
    end,
    [2] = function(rd, rs1, imm) -- LW
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local value = memory_read(addr, 4)
        if value then
            RegX[rd] = value
        else
            trap_raise(5, addr)
        end
    end,
    [4] = function(rd, rs1, imm) -- LBU
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local value = memory_read(addr, 1)
        if value then
            RegX[rd] = value
        else
            trap_raise(5, addr)
        end
    end,
    [5] = function(rd, rs1, imm) -- LHU
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local value = memory_read(addr, 2)
        if value then
            RegX[rd] = value
        else
            trap_raise(5, addr)
        end
    end
}

-- Store instructions lookup table
local store_handlers = {
    [0] = function(rs1, rs2, imm) -- SB
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local succ = memory_write(addr, RegX[rs2], 1)
        if not succ then
            trap_raise(7, addr) --- 7 = Store/AMO access fault
        end
    end,
    [1] = function(rs1, rs2, imm) -- SH
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local succ = memory_write(addr, RegX[rs2], 2)
        if not succ then
            trap_raise(7, addr)
        end
    end,
    [2] = function(rs1, rs2, imm) -- SW
        local addr = num_add(RegX[rs1], num_sext(imm, 12))
        local succ = memory_write(addr, RegX[rs2], 4)
        if not succ then
            trap_raise(7, addr)
        end
    end
}

-- Branch instructions lookup table
local branch_handlers = {
    [0] = function(rs1, rs2, imm) -- BEQ
        if RegX[rs1] == RegX[rs2] then
            Hart.pc_inc_amount = num_sext(imm, 13)
        end
    end,
    [1] = function(rs1, rs2, imm) -- BNE
        if RegX[rs1] ~= RegX[rs2] then
            Hart.pc_inc_amount = num_sext(imm, 13)
        end
    end,
    [4] = function(rs1, rs2, imm) -- BLT
        if num_signed(RegX[rs1], 32) < num_signed(RegX[rs2], 32) then
            Hart.pc_inc_amount = num_sext(imm, 13)
        end
    end,
    [5] = function(rs1, rs2, imm) -- BGE
        if num_signed(RegX[rs1], 32) >= num_signed(RegX[rs2], 32) then
            Hart.pc_inc_amount = num_sext(imm, 13)
        end
    end,
    [6] = function(rs1, rs2, imm) -- BLTU
        if RegX[rs1] < RegX[rs2] then
            Hart.pc_inc_amount = num_sext(imm, 13)
        end
    end,
    [7] = function(rs1, rs2, imm) -- BGEU
        if RegX[rs1] >= RegX[rs2] then
            Hart.pc_inc_amount = num_sext(imm, 13)
        end
    end
}

-- System instructions lookup table
local system_handlers = {
    [0] = function(funct12, rd, rs1) -- ECALL, EBREAK, MRET
        if funct12 == 0 then         -- ECALL
            if Hart.mode == Mode.User then
                trap_raise(8, 0)
            else
                trap_raise(11, 0)
            end
        elseif funct12 == 1 then   -- EBREAK
            trap_raise(3, 0)
        elseif funct12 == 770 then -- MRET
            local mstatus = assert(csrs_read(0x300))
            local mpie = (mstatus >> 7) & 0x1
            local mpp = (mstatus >> 11) & 0x3
            assert(mpp == 0 or mpp == 3)
            Hart.mode = mpp
            csrs_write(0x300, num_clear(mstatus, 6280) + (mpie * 8) + 128)
            Hart.pc = assert(csrs_read(0x341))
            Hart.pc_inc_amount = 0
        end
    end,
    [1] = function(funct12, rd, rs1) -- CSRRW
        local newval = RegX[rs1]
        if rd ~= 0 then
            local ocsr = csrs_read(funct12) or 0
            RegX[rd] = ocsr
        end
        csrs_write(funct12, newval)
    end,
    [2] = function(funct12, rd, rs1) -- CSRRS
        local ocsr = csrs_read(funct12) or 0
        local modval = RegX[rs1]
        RegX[rd] = ocsr
        if rs1 ~= 0 then
            csrs_write(funct12, num_bor(ocsr, modval))
        end
    end,
    [3] = function(funct12, rd, rs1) -- CSRRC
        local ocsr = csrs_read(funct12) or 0
        local modval = RegX[rs1]
        RegX[rd] = ocsr
        if rs1 ~= 0 then
            csrs_write(funct12, num_clear(ocsr, modval))
        end
    end,
    [5] = function(funct12, rd, rs1) -- CSRRWI
        local imm = rs1
        if rd ~= 0 then
            local ocsr = csrs_read(funct12) or 0
            RegX[rd] = ocsr
        end
        csrs_write(funct12, imm)
    end,
    [6] = function(funct12, rd, rs1) -- CSRRSI
        local imm = rs1
        local ocsr = csrs_read(funct12) or 0
        RegX[rd] = ocsr
        if imm ~= 0 then
            csrs_write(funct12, num_bor(ocsr, imm))
        end
    end,
    [7] = function(funct12, rd, rs1) -- CSRRCI
        local imm = rs1
        local ocsr = csrs_read(funct12) or 0
        RegX[rd] = ocsr
        if imm ~= 0 then
            csrs_write(funct12, num_clear(ocsr, imm))
        end
    end
}

-- AMO instructions lookup table
local amo_handlers = {
    [2] = function(rd, rs1, rs2) -- LR.W
        local addr = RegX[rs1]
        local data = memory_read(addr, 4)
        if data then
            RegX[rd] = data
        else
            trap_raise(5, addr) -- 5 = Load Access Fault
        end
    end,
    [3] = function(rd, rs1, rs2) -- SC.W
        local addr = RegX[rs1]
        local data = RegX[rs2]
        local succ = memory_write(addr, data, 4)
        if succ then
            RegX[rd] = 0
        else
            trap_raise(7, addr) -- Store/AMO Access Fault
        end
    end,
    [1] = function(rd, rs1, rs2) -- AMOSWAP.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            memory_write(addr, rs2v, 4)
            RegX[rd] = data
        else
            trap_raise(7, addr) -- Store/AMO Access Fault
        end
    end,
    [0] = function(rd, rs1, rs2) -- AMOADD.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            memory_write(addr, num_add(data, rs2v), 4)
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [4] = function(rd, rs1, rs2) -- AMOXOR.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            memory_write(addr, num_bxor(data, rs2v), 4)
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [12] = function(rd, rs1, rs2) -- AMOAND.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            memory_write(addr, num_band(data, rs2v), 4)
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [8] = function(rd, rs1, rs2) -- AMOOR.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            memory_write(addr, num_bor(data, rs2v), 4)
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [16] = function(rd, rs1, rs2) -- AMOMIN.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            if num_signed(data, 32) < num_signed(rs2v, 32) then
                memory_write(addr, data, 4)
            else
                memory_write(addr, rs2v, 4)
            end
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [20] = function(rd, rs1, rs2) -- AMOMAX.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            if num_signed(data, 32) > num_signed(rs2v, 32) then
                memory_write(addr, data, 4)
            else
                memory_write(addr, rs2v, 4)
            end
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [24] = function(rd, rs1, rs2) -- AMOMINU.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            if data < rs2v then
                memory_write(addr, data, 4)
            else
                memory_write(addr, rs2v, 4)
            end
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end,
    [28] = function(rd, rs1, rs2) -- AMOMAXU.W
        local addr = RegX[rs1]
        if memory_validWrite(addr, 4) and memory_validRead(addr, 4) then
            local data = memory_read(addr, 4)
            local rs2v = RegX[rs2]
            if data > rs2v then
                memory_write(addr, data, 4)
            else
                memory_write(addr, rs2v, 4)
            end
            RegX[rd] = data
        else
            trap_raise(7, addr)
        end
    end
}

local lui_handler = function(rd, imm)
    RegX[rd] = imm
end
local auipc_handler = function(rd, imm)
    RegX[rd] = num_add(imm, Hart.pc)
end
local jal_handler = function(rd, imm)
    RegX[rd] = Hart.pc + 4
    Hart.pc_inc_amount = imm
end

local jalr_handler = function(rs1, rd, imm)
    local base = RegX[rs1]
    local target = num_add(base, imm)
    target = target - (target % 2)
    RegX[rd] = Hart.pc + 4
    Hart.pc = target
    Hart.pc_inc_amount = 0
end

local INSTR_CACHE_MASK = 0x3FFFF
local instr_exec_cache = {}
local instr_exec_cache_pc = {}
local fencei_handler = function()
    for i = 1, INSTR_CACHE_MASK + 1 do
        instr_exec_cache[i] = 0
        instr_exec_cache_pc[i] = 0
    end
end
fencei_handler()
local nop_handler = function() end


-- Main opcode lookup table
local opcode_decoder = {
    [19] = function(inst) -- OP-IMM
        local funct3 = (inst >> 12) & 0x7
        local rd = (inst >> 7) & 0x1F
        local rs1 = (inst >> 15) & 0x1F
        local immediate = (inst >> 20) & 0xFFF
        immediate = num_sext(immediate, 12)

        local handler = op_imm_handlers[funct3]
        if handler then
            return handler, { inst, rd, rs1, immediate }
        else
            print("illegal instruction at " .. tostring(Hart.pc))
            return trap_raise, { 2, inst }
        end
    end,
    [51] = function(inst) -- OP
        local funct3 = (inst >> 12) & 0x7
        local rs1 = (inst >> 15) & 0x1F
        local rs2 = (inst >> 20) & 0x1F
        local rd = (inst >> 7) & 0x1F
        local funct7 = (inst >> 25) & 0x7F

        if funct7 == 1 then
            -- M extension
            local handler = m_extension_handlers[funct3]
            if handler then
                return handler, { rs1, rs2, rd }
            else
                print("illegal instruction at " .. tostring(Hart.pc))
                trap_raise(2, inst)
                return trap_raise, { 2, inst }
            end
        else
            -- Basic OP instructions
            local handler = op_handlers_basic[funct3]
            if handler then
                return handler, { rs1, rs2, rd, funct7 }
            else
                print("illegal instruction at " .. tostring(Hart.pc))
                trap_raise(2, inst)
                return trap_raise, { 2, inst }
            end
        end
    end,
    [3] = function(inst) -- LOAD
        local rd = (inst >> 7) & 0x1F
        local funct3 = (inst >> 12) & 0x7
        local rs1 = (inst >> 15) & 0x1F
        local imm = (inst >> 20) & 0xFFF

        local handler = load_handlers[funct3]
        if handler then
            return handler, { rd, rs1, imm }
        else
            print("illegal instruction at " .. tostring(Hart.pc))
            trap_raise(2, inst)
            return trap_raise, { 2, inst }
        end
    end,
    [35] = function(inst) -- STORE
        local funct3 = (inst >> 12) & 0x7
        local rs1 = (inst >> 15) & 0x1F
        local rs2 = (inst >> 20) & 0x1F
        local imm = s_type_imm(inst)

        local handler = store_handlers[funct3]
        if handler then
            return handler, { rs1, rs2, imm }
        else
            print("illegal instruction at " .. tostring(Hart.pc))
            trap_raise(2, inst)
            return trap_raise, { 2, inst }
        end
    end,
    [99] = function(inst) -- BRANCH
        local funct3 = (inst >> 12) & 0x7
        local rs1 = (inst >> 15) & 0x1F
        local rs2 = (inst >> 20) & 0x1F
        local imm = b_type_imm(inst)

        local handler = branch_handlers[funct3]
        if handler then
            return handler, { rs1, rs2, imm }
        else
            print("illegal instruction at " .. tostring(Hart.pc))
            trap_raise(2, inst)
            return trap_raise, { 2, inst }
        end
    end,
    [55] = function(inst) -- LUI
        local rd = (inst >> 7) & 0x1F
        local imm = (inst >> 12) & 0xFFFFF
        imm = imm << 12
        return lui_handler, { rd, imm }
    end,
    [23] = function(inst) -- AUIPC
        local rd = (inst >> 7) & 0x1F
        local imm = (inst >> 12) & 0xFFFFF
        imm = imm << 12
        return auipc_handler, { rd, imm }
    end,
    [111] = function(inst) -- JAL
        local rd = (inst >> 7) & 0x1F
        local imm20 = (inst >> 31) & 0x1
        local imm10_1 = (inst >> 21) & 0x3FF
        local imm11 = (inst >> 20) & 0x1
        local imm19_12 = (inst >> 12) & 0xFF
        local imm = imm20 * 2 ^ 20 + imm19_12 * 2 ^ 12 + imm11 * 2 ^ 11 + imm10_1 * 2 ^ 1
        imm = num_sext(imm, 21)
        return jal_handler, { rd, imm }
    end,
    [103] = function(inst) -- JALR
        local rs1 = (inst >> 15) & 0x1F
        local rd = (inst >> 7) & 0x1F
        local imm = (inst >> 20) & 0xFFF
        imm = num_sext(imm, 12)
        return jalr_handler, { rs1, rd, imm }
    end,
    [115] = function(inst) -- SYSTEM
        local funct3 = (inst >> 12) & 0x7
        local rd = (inst >> 7) & 0x1F
        local rs1 = (inst >> 15) & 0x1F
        local funct12 = (inst >> 20) & 0xFFF

        local handler = system_handlers[funct3]
        if handler then
            return handler, { funct12, rd, rs1 }
        else
            print("illegal instruction at " .. tostring(Hart.pc))
            trap_raise(2, inst)
            return trap_raise, { 2, inst }
        end
    end,
    [47] = function(inst) -- AMO
        local rd = (inst >> 7) & 0x1F
        local rs1 = (inst >> 15) & 0x1F
        local rs2 = (inst >> 20) & 0x1F
        local funct5 = (inst >> 27) & 0x1F

        local handler = amo_handlers[funct5]
        if handler then
            return handler, { rd, rs1, rs2 }
        else
            print("illegal instruction at " .. tostring(Hart.pc))
            trap_raise(2, inst)
            return trap_raise, { 2, inst }
        end
    end,
    [15] = function(inst) -- FENCE
        local funct3 = (inst >> 12) & 0x7
        local rd = (inst >> 7) & 0x1F
        local rs1 = (inst >> 15) & 0x1F
        local immediate = (inst >> 20) & 0xFFF
        if funct3 == 1 and rd == 0 and rs1 == 0 and immediate == 0 then
            -- FENCE.I
            -- 清空缓存
            return fencei_handler, {}
        else
            return nop_handler, {}
            -- fence instruction - no implementation needed for basic emulator
        end
    end
}

function Core.run(inst_per_loop, times)
    --local cacheMiss = 0
    for i = 1, times do
        local timediff = 1 / 30 / times
        local timer_int = CLINT.update(math.floor(timediff * 1000000 + 0.5)) -- our timer is in a bullshit hz but it works

        if timer_int then
            CSRs[0x344].v = num_bor(CSRs[0x344].v, 128)   -- set mip for timer
        else
            CSRs[0x344].v = num_clear(CSRs[0x344].v, 128) -- mip for timer
        end

        if (CSRs[0x300].v & 0x8) ~= 0 then -- mstatus.MIE
            if (CSRs[0x344].v & 0x80) ~= 0 and (CSRs[0x304].v & 0x80) ~= 0 then
                -- timer interrupt :tada:
                trap_raise(0x80000007, 0)
            end
        end

        --UART.update()

        for _ = 1, inst_per_loop do
            Hart.pc_inc_amount = 4
            local inst
            local cache_addr = ((Hart.pc >> 2) & INSTR_CACHE_MASK) + 1
            local cache_entry = instr_exec_cache[cache_addr]
            if cache_entry ~= 0 and instr_exec_cache_pc[cache_addr] == Hart.pc then
                cache_entry.handler(table.unpack(cache_entry.args))
            else
                inst = memory_read(Hart.pc, 4)
                --cacheMiss = cacheMiss + 1

                if not inst then
                    trap_raise(1, Hart.pc) -- 1 = Instruction Access Fault
                elseif inst & 3 == 3 then  -- normal 32-bit instruction
                    local opcode = inst & 0x7F

                    local handler_decoder = opcode_decoder[opcode]
                    if handler_decoder then
                        local final_handler, args = handler_decoder(inst)
                        final_handler(table.unpack(args))
                        instr_exec_cache[cache_addr] = { handler = final_handler, args = args }
                        instr_exec_cache_pc[cache_addr] = Hart.pc
                    else
                        print("illegal instruction at " .. tostring(Hart.pc))
                        trap_raise(2, inst)
                    end
                else
                    print("illegal instruction at " .. tostring(Hart.pc))
                    trap_raise(2, inst)
                end
            end
            Hart.pc = (Hart.pc + Hart.pc_inc_amount) & 0xFFFFFFFF
        end
    end
    --print(" instructions with " .. tostring(cacheMiss) .. " cache misses.")
end

return Core
