--[[
@module  xye_listener
@summary XYE 协议旁听驱动：只收不发，监听总线上所有 AA...55 帧
@version 1.0
@date    2026.11.24
@usage   硬件接线: USB-485 转接器接 Air780EPM 的 u1 (X=A Y=B E=GND)
         方向脚: GPIO25 (低电平=发送态，旁听模式初始设高=接收态)

         local lsn = require "xye_listener"
         lsn.init()
         lsn.set_sink(function(frame) ... end)  -- 收到一帧的回调

         frame 结构 (来自 xye_codec.try_decode):
           { ftype, unit_id, len, raw, fields(仅C0_RESP) }
]]

local codec = require "xye_codec"

-- ===== 硬件参数（EPM u1，旁听 XYE 总线） =====
local UART_ID    = 1
local BAUDRATE   = 4800       -- XYE 协议 4800 8N1
local DATABITS   = 8
local STOPBITS   = 1
local PARITY     = uart.NONE
local ORDER      = uart.LSB
local BUF_SIZE   = 1024
local EN_PIN     = 25         -- EPM u1 方向脚
local EN_LEVEL   = 0          -- 低电平=发送态 → 初始高电平=接收态
local RS485_DELAY_US = 20000  -- 发送→接收切换延时（微秒），旁听模式不触发但仍需配置

-- ===== 内部状态 =====
local _buffer = ""            -- 累计接收 buffer（含上次 remaining + 本次新收到）
local _sink = nil             -- 帧回调: sink(frame)
local _inited = false

-- ===== 辅助: 字节串 → HEX =====
local function to_hex(raw)
    local parts = {}
    for i = 1, #raw do
        parts[#parts + 1] = string.format("%02X", raw:byte(i))
    end
    return table.concat(parts, " ")
end

-- ===== UART 接收回调 =====
local function recv_cb(id, len)
    -- 循环读空 UART 所有可用数据
    local chunk = ""
    repeat
        local s = uart.read(id, 256)
        if #s > 0 then
            chunk = chunk .. s
        end
    until s == ""

    if #chunk == 0 then
        return
    end

    -- 追加到累计 buffer
    _buffer = _buffer .. chunk

    -- 调 codec 拆帧
    local frames, remaining = codec.try_decode(_buffer)
    _buffer = remaining

    -- 回调
    if _sink and #frames > 0 then
        for _, f in ipairs(frames) do
            _sink(f)
        end
    end
end

-- ===== UART 发送完成回调（旁听模式不发送，仅占位） =====
local function sent_cb(id)
    -- 什么都不做
end

-- ===== 对外 API =====
local _M = {}

function _M.set_sink(fn)
    _sink = fn
end

function _M.init()
    if _inited then
        return true
    end

    log.info("xye", "========== XYE Listener 初始化 ==========")
    log.info("xye", string.format("  uart=%d baud=%d 8N%d en_pin=%d en_level=%d",
        UART_ID, BAUDRATE, STOPBITS, EN_PIN, EN_LEVEL))

    -- 方向脚先置高（接收态），确保初始化期间不会误发
    -- gpio.setup 在 LuatOS 里如果 pin 号是数字会自动适配 gpio 模块
    pcall(function()
        gpio.setup(EN_PIN, gpio.OUTPUT)
        gpio.set(EN_PIN, 1)   -- 高电平 = 接收态
    end)

    -- 初始化 UART（旁听模式也必须给 en_pin/en_level，否则某些板子方向脚会飘）
    uart.setup(UART_ID, BAUDRATE, DATABITS, STOPBITS,
               PARITY, ORDER, BUF_SIZE,
               EN_PIN, EN_LEVEL, RS485_DELAY_US)

    uart.on(UART_ID, "receive", recv_cb)
    uart.on(UART_ID, "sent", sent_cb)

    _buffer = ""
    _inited = true

    log.info("xye", "========== XYE Listener 启动完成，开始旁听 ==========")
    return true
end

return _M
