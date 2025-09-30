
Num = {} -- a little thing for operations that limit to 32 bits.. and a bit more
-- assumed unsigned!
local BITMAX = 0xFFFFFFFF
local NEG_INTMAX = 1<<31
local NUMLIMIT = 1<<32
function Num.add(a,b)
	return (a+b) & 0xFFFFFFFF-- limit to 32 bits
end

function Num.isneg(a)
	return a >= 0x80000000
end

function Num.sub(a,b)
	-- return Num.add(a, Num.negate(b))
	return (a - b) & 0xFFFFFFFF
end

function Num.negate(a) -- the number is stored as **unsigned** in lua.
	return (- a) & 0xFFFFFFFF
end

---@param a integer
---@param bits integer
---@return integer
function Num.signed(a, bits)
	if a >= 1<<(bits - 1) then
		return a - (1<<bits)
	end

	return a;
end

function Num.rshift(a, amount)
	assert(amount >= 0)
	return (a&BITMAX)>>amount
end

function Num.lshift(a, amount)
	assert(amount >= 0)
	return (a<<amount) & 0xFFFFFFFF
end

function Num.band(a,b)
 
	return a & b
end

function Num.bor(a,b)
 
	return a|b
end

function Num.bxor(a,b)
 
	return a~b
end

function Num.clear(a,b) -- any bit set in b will be removed from a 
	return a & (~b) 
end

function Num.getBits(a, pos1, pos2) -- starts at 0. example: getBits(0b1010, 0, 1) == 0b10, getBits(0b1010, 1,2) == 0b01
	return ((a&((2<<pos2)-1))>>pos1)&BITMAX
end

local MASK16 = 0xFFFF
local SHIFT16 = 16
local MASK32 = 0xFFFFFFFF
local SHIFT32 = 32

function Num.multiply(a, b)
    -- Split into 16-bit chunks using bit operations (guaranteed integer)
    local al = a & MASK16
    local ah = a >> SHIFT16

    local bl = b & MASK16
    local bh = b >> SHIFT16

    -- Multiply 16-bit chunks (results are <= 32-bit, safe as integer)
    local p0 = al * bl          -- max: 0xFFFF * 0xFFFF = ~4.2e9 < 2^32
    local p1 = al * bh
    local p2 = ah * bl
    local p3 = ah * bh

    -- Combine middle terms
    local mid = p1 + p2         -- max 33 bits, but Lua int is 64-bit → safe
    local midl = mid & MASK16   -- lower 16 bits
    local midh = mid >> SHIFT16 -- upper bits

    -- Combine lower half
    local shit = p0 + (midl << SHIFT16)  -- p0 (32b) + midl<<16 (32b) → max 33b
    local lo = shit & MASK32             -- lower 32 bits
    local carry = shit >> SHIFT32        -- 33rd bit (0 or 1)

    -- Combine upper half
    local hi = (p3 + midh + carry) & MASK32

    return lo, hi
end

---@param a integer
---@param bits integer
function Num.sext(a, bits)
	if Num.getBits(a, bits - 1, bits - 1) == 1 then
		return (a|((BITMAX>>bits)<<bits)) & BITMAX
	end
	return a
end