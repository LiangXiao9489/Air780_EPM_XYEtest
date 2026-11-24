

require "sys"

PROJECT = "test_XYE_bus_protocol"
VERSION = "1.0.000"

pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

log.error("main", "====================================================")
log.error("main", "====================================================")
log.error("main", "工程名称: " .. PROJECT)
log.error("main", "固件版本: " .. VERSION)
log.error("main", "====================================================")
log.error("main", "====================================================")


-- ========== XYE Listener 硬件测试 ==========
local listener = require "xye_listener"
local codec    = require "xye_codec"

-- 统计
local total_frames = 0
local frame_count = {}         -- ftype -> count
local online_units = {}        -- unit_id -> { last_seen_tick, ftypes }
local unknown_count = 0

-- sink: 每收到一帧就回调
local printed_units = {}   -- 已全量打印过字段的设备 unit_id

local function on_frame(frame)
    total_frames = total_frames + 1

    -- 帧类型计数
    frame_count[frame.ftype] = (frame_count[frame.ftype] or 0) + 1

    -- 统计在线设备: 只认应答帧（C0_RESP/C1_RESP）——轮询帧的 unit_id 是主站在"问谁"
    if frame.unit_id and (frame.ftype == "C0_RESP" or frame.ftype == "C1_RESP") then
        local id = frame.unit_id
        if not online_units[id] then
            online_units[id] = { first_tick = mcu.ticks(), last_tick = mcu.ticks(), ftypes = {} }
            log.info("XYE", string.format("新设备上线: unit_id=0x%02X", id))
        end
        local info = online_units[id]
        info.last_tick = mcu.ticks()
        info.ftypes[frame.ftype] = (info.ftypes[frame.ftype] or 0) + 1

        -- 每台设备第一次收到 C0_RESP 时全量打印所有字段
        if frame.ftype == "C0_RESP" and frame.fields and not printed_units[id] then
            printed_units[id] = true
            local f = frame.fields
            log.info("XYE", string.format("========== C0_RESP 全量字段 单元ID=0x%02X ==========", id))
            log.info("XYE", string.format("  原始帧HEX: %s", codec.to_hex(frame.raw)))
            log.info("XYE", string.format("  [能力]    能力标志=0x%02X  支持摆风=%s  支持室外温度=%s",
                f.caps, f.caps_sw and "是" or "否", f.caps_extemp and "是" or "否"))
            log.info("XYE", string.format("  [模式]    运行模式=0x%02X  风扇模式=0x%02X  自动风=%s  当前风速档位=0x%01X",
                f.op_mode, f.fan_mode, f.fan_auto and "是" or "否", f.fan_speed))
            log.info("XYE", string.format("  [温度]    设定温度=%.1f°C(raw=0x%02X)  室内回风T1=%.1f  盘管T2=%.1f  盘管排T2B=%s  室外T3=%s  电流raw=0x%02X",
                f.target_temp or -99, f.target_temp_raw,
                f.t1_temp or -99, f.t2_temp or -99,
                f.t2b_temp and string.format("%.1f", f.t2b_temp) or "nil",
                f.t3_temp and string.format("%.1f", f.t3_temp) or "nil",
                f.current))
            log.info("XYE", string.format("  [运行]    压缩机=%s  定时启动=0x%02X(%s)  定时关机=0x%02X(%s)",
                f.compressor_run == 1 and "运行中" or "已停机",
                f.timer_start, tostring(f.timer_start_h and f.timer_start_h .. "小时" or "未设置"),
                f.timer_stop,  tostring(f.timer_stop_h  and f.timer_stop_h  .. "小时" or "未设置")))
            log.info("XYE", string.format("  [模式标志]  ECO节能=%s  电辅热AUX=%s  摆风SWING=%s  (raw=0x%02X)",
                f.mode_eco and "是" or "否", f.mode_aux and "是" or "否",
                f.mode_swing and "是" or "否", f.mode_flags))
            log.info("XYE", string.format("  [运行标志]  水泵运行=%s  水锁保护=%s  (raw=0x%02X)",
                f.op_waterpump and "是" or "否", f.op_waterlock and "是" or "否", f.op_flags))
            log.info("XYE", string.format("  [故障码]  故障标志=0x%02X%02X",
                f.err_flags_high, f.err_flags_low))
            log.info("XYE", string.format("  [保护状态]  保护标志=0x%02X%02X  除霜中=%s",
                f.prot_flags_high, f.prot_flags_low, f.prot_defrost and "是" or "否"))
            log.info("XYE", string.format("  [通信错误]  CCM通信错误标志=0x%02X", f.ccm_err))
            log.info("XYE", string.format("  [未知字节]  byte7=0x%02X byte17=0x%02X byte28=0x%02X byte29=0x%02X byte30=0x%02X  (byte28+byte29候选EEV步数=%d)",
                f.unknown_1, f.unknown_2, f.byte28, f.byte29, f.byte30, f.eev_steps))
            log.info("XYE", "  =========================================================")
        end
    end

    if frame.ftype:sub(1, 7) == "UNKNOWN" then
        unknown_count = unknown_count + 1
        if unknown_count <= 5 then
            log.warn("XYE", "UNKNOWN frame len=" .. frame.len .. " hex=" .. codec.to_hex(frame.raw))
        end
    end
end

listener.set_sink(on_frame)
listener.init()

-- 每 5 秒打印一次统计
sys.timerLoopStart(function()
    log.error("XYE", string.format("===== 统计 tick=%d =====", mcu.ticks()))
    log.error("XYE", string.format("  总帧数: %d  UNKNOWN: %d", total_frames, unknown_count))
    local fc = {}
    for k, v in pairs(frame_count) do fc[#fc+1] = k .. "=" .. v end
    log.error("XYE", "  类型分布: " .. table.concat(fc, ", "))

    local ids = {}
    for id, _ in pairs(online_units) do ids[#ids+1] = string.format("0x%02X", id) end
    table.sort(ids)
    log.error("XYE", string.format("  在线设备 (%d台): %s", #ids, table.concat(ids, " ")))
end, 5000)
-- ========== XYE Listener 硬件测试结束 ==========

sys.run()
