

require "sys"

-- 硬件资源表（单板 EPM，写死）
local board = require "board"

-- 运行时配置（JSON 落盘）
local config = require "config"

-- 点位缓存（单板 EPM）
local store = require "store"
store.init()

-- 外部硬件看门狗（Air153C，EPM 板 GPIO28），require 后自动启动喂狗 task
require "ext_wdt"

PROJECT = "test_XYE_bus_protocol"
VERSION = "1.0.000"

pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

log.error("main", "====================================================")
log.error("main", "====================================================")
log.error("main", "工程名称: " .. PROJECT)
log.error("main", "固件版本: " .. VERSION)
log.error("main", "====================================================")
log.error("main", "====================================================")

-- ========== store 缓存层启动测试（临时，步骤3通过后删除） ==========
log.info("store.test", "===== store 缓存层启动测试 =====")
store.ensure_device(0x08)
store.write_point(0x08, "op_mode", 1, 0)
store.write_point(0x08, "t1_temp", 26, 0)
store.write_point(0x08, "compressor_run", 1, 0)
store.ensure_device(0x09)
store.write_point(0x09, "op_mode", 0, 0)
store.write_point(0x09, "t1_temp", 28, 0)
store.write_point(0x09, "fault_code", 0, 0)
log.info("store.test", "is_ready=", store.is_ready())
log.info("store.test", "online_devices=", table.concat(store.get_online_devices(), ","))
local vals = store.get_point_values()
log.info("store.test", "get_point_values 返回条数=" .. #vals)
for _, p in ipairs(vals) do
    log.info("store.test", string.format("  dev=0x%02X tag=%-16s value=%s errcode=0x%02X ts=%s",
        p.dev_id, p.tag, tostring(p.values and p.values[1]), p.errcode, tostring(p.ts)))
end
-- 测试离线
store.write_device_offline(0x09, 0x0B)
local v2 = store.get_point_values()
local offline_count = 0
for _, p in ipairs(v2) do
    if p.dev_id == 0x09 and p.errcode == 0x0B then offline_count = offline_count + 1 end
end
log.info("store.test", string.format("离线测试: 0x09 设备 errcode=0x0B 的点位=%d", offline_count))
log.info("store.test", "===== store 测试完成 =====")

-- ========== XYE Listener 硬件测试 ==========
local listener = require "xye_listener"
local codec    = require "xye_codec"
local profile  = require "xye_profile"

-- 统计
local total_frames = 0
local frame_count = {}         -- ftype -> count
local online_units = {}        -- unit_id -> { last_seen_tick, ftypes }
local unknown_count = 0

-- sink: 每收到一帧就回调
local printed_units = {}   -- 已全量打印过 C0 字段的设备 unit_id
local printed_c1    = {}   -- 已打印过 C1 结构的设备 unit_id
local printed_aa    = {}   -- 已打印过的 AA 短帧 cmd

-- Modbus 点位映射所需
local latest      = {}     -- unit_id -> { c0 = fields, c1 = fields }
local printed_pm  = {}     -- 已打印过 Modbus 点表的设备
local printed_sys = false  -- 系统级点表是否已打印

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

        -- 每台设备第一次收到 C1_RESP 时打印结构化原始数据（语义待 P3 差分）
        if frame.ftype == "C1_RESP" and frame.fields and not printed_c1[id] then
            printed_c1[id] = true
            local c = frame.fields
            log.info("XYE", string.format("-------- C1_RESP 结构 单元ID=0x%02X --------", id))
            log.info("XYE", string.format("  原始帧HEX: %s", codec.to_hex(frame.raw)))
            log.info("XYE", string.format("  值A(byte7)=0x%02X  值B(byte9)=0x%02X  设备固有(byte28)=0x%02X  (sentinel b8=0x%02X b10=0x%02X)",
                c.val_a, c.val_b, c.dev_const, c.sentinel_1, c.sentinel_2))
            log.info("XYE", string.format("  payload原值(b6..b30): %s", c.payload_hex))
            log.info("XYE", "  (语义未确认，待 P3 差分分析)")
        end
    end

    -- AA 短帧：每个 cmd 只打印一次（cmd = unit_id + 1）
    if frame.ftype == "AA" and frame.fields and not printed_aa[frame.fields.cmd] then
        printed_aa[frame.fields.cmd] = true
        local a = frame.fields
        if a.unit_id then
            log.info("XYE", string.format("-------- AA短帧 cmd=0x%02X → 单元ID=0x%02X --------", a.cmd, a.unit_id))
        else
            log.info("XYE", string.format("-------- AA短帧 cmd=0x%02X (全局帧) --------", a.cmd))
        end
        log.info("XYE", string.format("  原始帧HEX: %s", codec.to_hex(frame.raw)))
        log.info("XYE", string.format("  payload原值: %s%s", a.payload_hex,
            a.all_zero and "  (全零 = 该槽位空闲/无数据)" or ""))
        if a.unit_id then
            log.info("XYE", string.format("  标志=0x%02X  值A(payload[2]↔C1 byte7)=0x%02X  值B(payload[3])=0x%02X  尾=0x%02X 0x%02X 0x%02X",
                a.p1, a.p2, a.p3, a.p4, a.p5, a.p6))
        else
            log.info("XYE", string.format("  标志=0x%02X  payload[2..6]=0x%02X 0x%02X 0x%02X 0x%02X 0x%02X",
                a.p1, a.p2, a.p3, a.p4, a.p5, a.p6))
        end
    end

    -- ===== Modbus 点位映射 =====
    local uid = frame.unit_id
    if uid and frame.fields then
        local slot = latest[uid]
        if not slot then
            slot = {}
            latest[uid] = slot
        end
        if frame.ftype == "C0_RESP" then
            slot.c0 = frame.fields
        elseif frame.ftype == "C1_RESP" then
            slot.c1 = frame.fields
        end

        -- 每台内机：C0 + C1 都到齐后打印一次点位表
        if slot.c0 and slot.c1 and not printed_pm[uid] then
            printed_pm[uid] = true
            log.info("PMAP", string.format("===== Modbus 点表 单元ID=0x%02X =====", uid))
            for _, p in ipairs(profile.unit_points) do
                local fields = (p.src == "c1") and slot.c1 or slot.c0
                local addr = profile.unit_addr(p, uid)
                if addr then
                    local v = profile.point_value(p, fields)
                    local vs
                    if v == nil then
                        vs = "(无数据)"
                    elseif p.kind == "DI" then
                        vs = (v == 1) and "1/是" or "0/否"
                    elseif p.scale then
                        vs = string.format("%d (÷%d=%.1f)", v, p.scale, v / p.scale)
                    else
                        vs = tostring(v)
                    end
                    log.info("PMAP", string.format("  %s[0x%04X] %s = %s", p.kind, addr, p.cn, vs))
                end
            end
        end
    end

    -- 系统级共享点位：首次拿到任一 C0 帧后打印一次
    if not printed_sys and frame.ftype == "C0_RESP" and frame.fields then
        printed_sys = true
        log.info("PMAP", "===== Modbus 点表（系统级共享）=====")
        for _, p in ipairs(profile.system_points) do
            local addr = profile.sys_addr(p)
            local v = profile.point_value(p, frame.fields)
            local vs
            if v == nil then
                vs = "(无数据)"
            elseif p.kind == "DI" then
                vs = (v == 1) and "1/是" or "0/否"
            elseif p.scale then
                vs = string.format("%d (÷%d=%.1f)", v, p.scale, v / p.scale)
            else
                vs = tostring(v)
            end
            log.info("PMAP", string.format("  %s[0x%04X] %s = %s", p.kind, addr, p.cn, vs))
        end
        log.info("PMAP", string.format("  地址空间: IR 共 %d 个, DI 共 %d 个",
            profile.IR_TOTAL, profile.DI_TOTAL))
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
