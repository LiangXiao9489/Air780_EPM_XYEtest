

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
    end

    -- 前 10 帧详细打印（含字段解码），避免刷屏
    if total_frames <= 10 then
        local tag = frame.unit_id and string.format("unit=0x%02X", frame.unit_id) or "no-unit"
        log.info("XYE", string.format("[%d] %-12s %s len=%d",
            total_frames, frame.ftype, tag, frame.len))
        if frame.fields then
            local f = frame.fields
            log.info("XYE", string.format("    mode=0x%02X fan=0x%02X t1=%.1f t2=%.1f comp=%d",
                f.op_mode, f.fan_mode,
                f.t1_temp or -99, f.t2_temp or -99,
                f.compressor_run))
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
