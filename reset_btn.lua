--[[
@module  reset_btn
@summary 长按 reload 按键 7 秒恢复出厂（删除 /gateway_cfg.json + 重启）
@version 1.0
@date    2026.11.18
@usage
reload 按键连接：内部上拉，按下接 GND → 按下读 0，松开读 1。
  EPM: GPIO30
  EHV: GPIO26
  引脚从 profile.reload_pin 取。

逻辑：
  每 100ms 采样一次引脚；
  按住期间累加计时；一旦松开 → 清零；
  连续按住 ≥ 7000ms → 调用 config.factory_reset()（删配置文件 + 重启）。

为了让现场人员知道"长按是否被检测到"，按住第 3 秒起在日志里打印一次进度提示。
本文件没有对外接口，main.lua 中 require "reset_btn" 即自动运行。
]]

-- 单板 EPM，GPIO30 长按恢复出厂
local RESET_PIN = 30

local config = require "config"

local TARGET_MS  = 7000   -- 长按判定阈值
local TICK_MS    = 100    -- 采样周期
local progress_logged = false

local function reset_btn_task()
    gpio.setup(RESET_PIN, 1, gpio.PULLUP)   -- 默认高（上拉）

    local hold_ms = 0

    while true do
        local pressed = (gpio.get(RESET_PIN) == 0)   -- 按下 → 接地 → 0

        if pressed then
            hold_ms = hold_ms + TICK_MS

            -- 第 3 秒（及之后）打一条进度，避免一直刷屏
            if not progress_logged and hold_ms >= 3000 then
                log.info("reset_btn", "检测到长按",
                         "已按住 " .. hold_ms .. "ms",
                         "阈值 " .. TARGET_MS .. "ms")
                progress_logged = true
            end

            if hold_ms >= TARGET_MS then
                log.warn("reset_btn", "长按达到阈值！",
                         "hold=" .. hold_ms .. "ms",
                         "执行恢复出厂...")
                config.factory_reset()
                -- factory_reset 内部会 rtos.reboot()，理论上走不到这里
                while true do sys.wait(1000) end
            end
        else
            if hold_ms > 0 then
                log.info("reset_btn", "按键松开",
                         "本次按住 " .. hold_ms .. "ms（< " .. TARGET_MS .. "ms，取消）")
            end
            hold_ms = 0
            progress_logged = false
        end

        sys.wait(TICK_MS)
    end
end

sys.taskInit(reset_btn_task)
log.info("reset_btn", "已启动",
         "pin=GPIO" .. tostring(RESET_PIN),
         "threshold=" .. TARGET_MS .. "ms")
