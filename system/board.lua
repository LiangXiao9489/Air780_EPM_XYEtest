--[[
@module  board
@summary EPM 单板硬件资源表（写死，无板型识别）
@version 1.0
@date    2026.11.27
@usage
本工程只面向 Air780 EPM（D700Tm 系列）单板，不需要板型识别。
所有后续模块从 board 读引脚常量，绝不自己写数字。

硬件依据（D700Tm 系列资源表 / Air780EPM 方案）：
  RS4851        串口1   EN=GPIO25, XYE 总线 4800 8N1
  NET LED       GPIO27
  硬件看门狗    GPIO28（Air153C）
  Reload 按键   GPIO30
]]

local _M = {}

-- ============================================================
-- 基本信息
-- ============================================================
_M.name    = "EPM"
_M.bsp     = rtos.bsp() or "epm"

-- ============================================================
-- 引脚定义
-- ============================================================
_M.led_pin    = 27   -- NET LED（高电平亮）
_M.wdt_pin    = 28   -- Air153C 看门狗
_M.reload_pin = 30   -- 复位按键

-- ============================================================
-- 串口 1（XYE 总线，旁听/发送都用这个）
-- ============================================================
_M.u1 = {
    uartid     = 1,
    baudrate   = 4800,      -- XYE 协议 4800 8N1
    databits   = 8,
    stopbits   = 1,
    parity     = "N",
    en_pin     = 25,        -- 485 方向脚
    en_level   = 0,         -- 低电平=发送态
    rs485_delay = 20000,    -- 发送→接收切换延时（微秒）
    clear_rx_on_send = true,
}

log.info("board", "EPM profile 已加载 bsp=" .. _M.bsp,
         string.format("LED=GPIO%d WDT=GPIO%d RELOAD=GPIO%d U1=4800",
             _M.led_pin, _M.wdt_pin, _M.reload_pin))

return _M
