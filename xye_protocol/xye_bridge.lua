--[[
@module  xye_bridge
@summary XYE 旁听帧 → store 缓存（单板 EPM，无 Modbus 中间层）
@version 1.0
@date    2026.11.27
@usage
  require "xye_bridge".start()

职责：
  - 订阅 xye_listener 的帧回调
  - 只处理 C0_RESP（全量字段）和 C1_RESP（仅作在线判定）
  - 主站发的轮询帧（C0_POLL/C1_POLL）、AA 短帧、C3_SET 全部忽略
  - 按 C0 字段内容写 store 缓存
  - 离线判定：连续 OFFLINE_MS 无应答 → 设备所有点 errcode 置 0x0B

与二合一版本的区别：
  - unit_id 直接用，不再 +1 转 Modbus 从站号
  - 不用 store.get_reg_by_tag（二合一依赖 Modbus 点表查地址），直接 store.write_point
  - 不需要 s_addr/n_addr 映射层
]]

local store = require "store"

-- ===== 参数 =====
local OFFLINE_MS = 45000       -- 45s 无应答判离线（约 3 轮 × 13.45s/轮）
local CHECK_MS   = 5000        -- 离线检查周期
local ERR_OFFLINE = 0x0B       -- 离线 errcode（沿用 Modbus 0x0B 含义：目标设备无响应）

-- ===== 状态 =====
local seen_ms = {}             -- unit_id → 最近一次应答的 mcu.ticks()

-- ============================================================
-- 工具
-- ============================================================
local function b2i(v)
    return v and 1 or 0
end

-- ============================================================
-- C0 应答 → 写缓存
-- tag 名统一用 codec 原始字段名（snake_case），以后加 Modbus 时做 tag→s_addr 映射即可
-- ============================================================
local function apply_c0(unit_id, x)
    -- byte11 设定温度：raw 含 bit6 状态位，清掉才是实际温度；0xFF 视为无数据
    local set_temp = x.target_temp_raw
    if set_temp == 0xFF then
        set_temp = nil
    else
        set_temp = set_temp & 0xBF
    end

    -- 基础运行参数
    store.write_point(unit_id, "op_mode",    x.op_mode)
    store.write_point(unit_id, "fan_mode",   x.fan_mode)
    store.write_point(unit_id, "set_temp",   set_temp)
    store.write_point(unit_id, "target_temp_raw", x.target_temp_raw)

    -- 温度（codec 已解码成整数℃）
    store.write_point(unit_id, "t1_temp",    x.t1_temp)
    store.write_point(unit_id, "t2_temp",    x.t2_temp)
    store.write_point(unit_id, "t2b_temp",   x.t2b_temp)
    store.write_point(unit_id, "t3_temp",    x.t3_temp)

    -- 故障 / 保护码（高低字节拼成 16-bit）
    store.write_point(unit_id, "fault_code",
        (x.err_flags_high or 0) * 256 + (x.err_flags_low or 0))
    store.write_point(unit_id, "protect_code",
        (x.prot_flags_high or 0) * 256 + (x.prot_flags_low or 0))

    -- 运行标志（布尔转 0/1）
    store.write_point(unit_id, "compressor_run", b2i(x.compressor_run == 1))
    store.write_point(unit_id, "op_waterpump",  b2i(x.op_waterpump))
    store.write_point(unit_id, "mode_eco",      b2i(x.mode_eco))
    store.write_point(unit_id, "mode_aux",      b2i(x.mode_aux))
    store.write_point(unit_id, "mode_swing",    b2i(x.mode_swing))

    -- 能力标志
    store.write_point(unit_id, "caps",        x.caps)
    store.write_point(unit_id, "mode_flags",  x.mode_flags)
    store.write_point(unit_id, "op_flags",    x.op_flags)
    store.write_point(unit_id, "ccm_err",     x.ccm_err)

    -- 电流（常为 0xFF，IDU 侧不量电流）
    store.write_point(unit_id, "current",     x.current)
end

-- ============================================================
-- 在线 / 离线判定
-- ============================================================
local function mark_online(unit_id)
    seen_ms[unit_id] = mcu.ticks()
    store.ensure_device(unit_id)
end

local function offline_task()
    while true do
        sys.wait(CHECK_MS)
        local now = mcu.ticks()
        for uid, last_seen in pairs(seen_ms) do
            if (now - last_seen) >= OFFLINE_MS then
                seen_ms[uid] = nil   -- 从在线列表移除
                store.write_device_offline(uid, ERR_OFFLINE)
                log.warn("xye", string.format("设备离线 unit_id=0x%02X 超时=%ds",
                    uid, math.floor((now - last_seen) / 1000)))
            end
        end
    end
end

-- ============================================================
-- 帧入口（xye_listener 的 sink）
-- ============================================================
local _M = {}

function _M.on_frame(f)
    local unit_id = f.unit_id

    -- unit_id 0x00~0x3F 才是室内机；0x80/0xFF 之类 CCM/广播帧忽略
    if not unit_id or unit_id > 0x3F then
        return
    end

    if f.ftype == "C0_RESP" then
        mark_online(unit_id)
        if f.fields then
            apply_c0(unit_id, f.fields)
        end

    elseif f.ftype == "C1_RESP" then
        -- C1 业务语义未确认，只作在线依据；数据点位等 C0
        mark_online(unit_id)
    end
    -- AA 短帧 / C0_POLL / C1_POLL / C3_SET 全部忽略
end

function _M.start()
    -- 离线判定 task 自启
    sys.taskInit(offline_task)
    log.info("xye", string.format("XYE bridge 已启动（离线=%ds）", OFFLINE_MS / 1000))
    return true
end

return _M
