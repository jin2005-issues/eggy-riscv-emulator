
LuaAPI.enable_experimental_feature(true)
local base85 = require("base85") 
local Zstd = Asset.Zstd
local ScreenID = require("Data.UINodes").Screen 



local RISCV = require("riscv.core")

local VT100 = require("vt100")

local ScreenUI = LuaAPI.query_ui_node(ScreenID)
require("keyboard")
Terminal = VT100:new(ScreenID)

Image = require("Image_part1")
---@export
---@desc append Image
---@param data string
function appendImage(data)
    Image = Image .. data
end

local runSpeed = 40000
---@export
---@desc set running speed
---@param speed number
function setSpeed(speed)
    runSpeed = speed 
end
local coreRunning = false 
---@export
---@desc start riscv core
function startCore()
    if coreRunning then
        return
    end
    --for i = 1, #oImage do
    --    if oImage:byte(i,i) ~= Image:byte(i,i) then
    --        print("Image mismatch at byte "..i)
    --        local origin = oImage:sub(math.max(1,i-10), math.min(#oImage,i+10))
    --        print("Original: "..origin.." New: "..Image:sub(math.max(1,i-10), math.min(#Image,i+10)))
    --        return
    --    end
    --end
    --print("Image verified, starting core...")
    local decodedData = base85.decode(Image)
    local data = Zstd.decompress(decodedData)
    for i = 1, #data do
        Ram.set(i - 1, data:byte(i, i))
    end 
    coreRunning = true
end

---@export
---@desc uart send string
---@param str string
function uartSendString(str)
    for i = 1, #str do
        UART.inputBuffer[#UART.inputBuffer + 1] = string.byte(str, i)
    end
end

local toggleCount = 0
local function onPreTick()
    if not coreRunning then
        return
    end
    RISCV.run(runSpeed//10, 10)
    toggleCount = toggleCount + 1
    if toggleCount >= 9 then
        toggleCount = 0
        Terminal:toggle_cursor_blink()
    end
    Terminal:render()
   --if not playing or not videoByteStream then
   --    return
   --end
   --if frameIndex % 2 == 0 then
   --    frameIndex = frameIndex + 1
   --    return
   --end
   --local playFrame = (frameIndex + 1) // 2
   --local startIndex = ((playFrame-1) * BYTES_PER_FRAME) + 1
   --local endIndex = startIndex + BYTES_PER_FRAME - 1
   --if (playFrame-1)% SOUND_SECTION_LEN == 0 then
   --    local soundSection = (playFrame -1)//SOUND_SECTION_LEN + 1
   --    LuaAPI.global_send_custom_event("SoundSection"..soundSection, {})
   --    print("Sound section: "..soundSection)
   --end

   --if endIndex > #videoByteStream then
   --    playing = false
   --    LuaAPI.global_send_custom_event("playEnd",{})
   --    return
   --end 
   --local white = string.pack("<BBBB", 255, 255, 255, 255)
   --local black = string.pack("<BBBB", 0, 0, 0, 255)
   --local mapI = 1
   --for i = startIndex, endIndex do
   --    local theByte = videoByteStream[i]
   --    for k = 7,0,-1 do
   --        local theBit = (theByte>>k)&1
   --        if theBit == 1 then
   --            canvas.color_map[mapI] = white
   --        else
   --            canvas.color_map[mapI] = black 
   --        end
   --        mapI = mapI + 1
   --    end
   --end
   --canvas.screen:update(canvas.color_map)  
   --frameIndex = frameIndex + 1
end
local function onPostTick()
end
LuaAPI.set_tick_handler(onPreTick, onPostTick)
 