--[[
@module  net_led
@summary NET LED 状态指示：MQTT 已连 → 常亮；否则快闪
@version 1.0
@date    2026.11.18
@usage
两板 NET LED 均为 GPIO27（高电平亮），引脚从 profile.led_pin 取。

状态机：
  mqtt_online = true   → 常亮
  mqtt_online = false  → 快闪（100ms 周期）

事件源（wireless/mqtt/basic.lua publish）：
  "MQTT_CONNECTED"      connect success 时触发
  "MQTT_DISCONNECTED"   任何断开/异常/重连时触发（含 broker 拒绝、IP 丢失、被动断开）

启动时默认 mqtt_online=false，先快闪着等网络。
本文件没有对外接口，main.lua 中 require "net_led" 即自动运行。
]]

-- 单板 EPM，GPIO27 高电平亮
local LED_PIN = 27

-- 当前连接状态（默认离线，先快闪着等）
local mqtt_online = false

-- 事件回调（只改状态，task 负责刷灯）
local function on_connected()
    mqtt_online = true
    log.info("net_led", "MQTT 已连接 → 常亮")
end

local function on_disconnected()
    if mqtt_online then
        log.warn("net_led", "MQTT 已断开 → 快闪")
    end
    mqtt_online = false
end

sys.subscribe("MQTT_CONNECTED",    on_connected)
sys.subscribe("MQTT_DISCONNECTED", on_disconnected)

-- 主 task：根据状态决定灯行为
local function net_led_task()
    gpio.setup(LED_PIN, 0, gpio.PULLDOWN)

    while true do
        if mqtt_online then
            -- 常亮：设 1，然后睡一个长周期，醒来再确认状态没变
            gpio.set(LED_PIN, 1)
            sys.wait(1000)
        else
            -- 快闪：100ms 周期（50ms 亮 + 50ms 灭）
            gpio.set(LED_PIN, 1)
            sys.wait(50)
            gpio.set(LED_PIN, 0)
            sys.wait(50)
        end
    end
end

sys.taskInit(net_led_task)
log.info("net_led", "已启动（初始状态：离线快闪）")
