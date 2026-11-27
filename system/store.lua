--[[
@module  store
@summary 轻量点位缓存（单板 EPM，tag 字符串索引，无 Modbus 地址映射）
@version 1.0
@date    2026.11.27
@usage
整个工程唯一的数据源：
  XYE 采集（xye_bridge）→ 写缓存
  MQTT 上报（report）→ 读缓存（get_point_values）

数据结构（极简，以后加协议转换不影响）：
  cache[unit_id][tag] = { value, errcode, ts }
  unit_id  = XYE 协议里的实际单元号（0x08/0x09/...）
  tag      = 字符串（"op_mode" "t1_temp" "compressor_run" ...）
  以后加 Modbus 时，只需加一层 tag→地址映射表，这个缓存层完全不动

对齐二合一 report.lua 所需接口：
  is_ready()                 缓存层就绪（init 后恒 true）
  ensure_device(unit_id)     登记新设备（空实现，缓存按需建）
  write_point(unit_id, tag, value, errcode)  写一个点位
  write_device_offline(unit_id, errcode)     设备离线：所有点写同一个 errcode
  get_point_values()         返回所有设备所有点的聚合值（report 依赖）
  get_online_devices()       当前有数据的 unit_id 列表（调试用）
]]

local _M = {}

-- 错误码（与二合一保持，以后加 Modbus 时可直接复用）
_M.ERR_UNINIT    = 0x08   -- 未采集过（缓存状态标记）
_M.ERR_NOT_FOUND = 0x02   -- 点位不存在（set_by_tag 查不到 tag 时）
_M.ERR_READONLY  = 0x04   -- 只读点位（set_by_tag 试图写只读 tag 时）
_M.ERR_NOT_SUPPORTED = 0x06  -- 单板 EPM 无写穿透能力

-- ============================================================
-- 内部数据
-- ============================================================
-- cache[unit_id][tag] = { value, errcode, ts }
local cache = {}
local ready = false

-- 已知设备列表（unit_id → true），ensure_device 登记用
local known_devs = {}

-- ============================================================
-- 对外 API
-- ============================================================

-- 空 init（没有点表要展开）
function _M.init()
    cache = {}
    known_devs = {}
    ready = true
    log.info("store", "缓存层初始化完成（单板 EPM，无点表，按需建）")
end

function _M.is_ready()
    return ready
end

-- 登记新设备（空实现：缓存按需建，不需要预注册）
function _M.ensure_device(unit_id)
    known_devs[unit_id] = true
    if not cache[unit_id] then
        cache[unit_id] = {}
        log.info("store", "设备登记", string.format("unit_id=0x%02X", unit_id))
    end
    return true
end

-- 写一个点位（采集侧调用）
-- unit_id: XYE 单元号
-- tag:     字符串点位名
-- value:   数值
-- errcode: 0=正常，其他=错误码
function _M.write_point(unit_id, tag, value, errcode)
    if not cache[unit_id] then
        cache[unit_id] = {}
    end
    cache[unit_id][tag] = {
        value    = value,
        errcode  = errcode or 0,
        ts       = os.time(),
    }
end

-- 设备离线：所有点位写同一个 errcode
function _M.write_device_offline(unit_id, errcode)
    local dev = cache[unit_id]
    if not dev then return end
    local code = errcode or 0x0B
    local count = 0
    for tag, slot in pairs(dev) do
        slot.errcode = code
        slot.ts = os.time()
        count = count + 1
    end
    log.warn("store", string.format("设备离线 unit_id=0x%02X 点位=%d errcode=0x%02X",
        unit_id, count, code))
end

-- 读一个点位（调试用）
function _M.read_point(unit_id, tag)
    local dev = cache[unit_id]
    if not dev then return nil end
    local slot = dev[tag]
    if not slot then return nil end
    return slot.value, slot.errcode, slot.ts
end

-- 当前有数据的 unit_id 列表
function _M.get_online_devices()
    local ids = {}
    for id, _ in pairs(cache) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

-- 供 report.start_index_real 调用：判断 (dev_id, tag) 是否是有效点位
-- 单板 EPM 没有 Modbus 地址映射层，所有在缓存里出现过的 tag 都算有效
-- 返回一个 truthy 值即可（Modbus 场景下是寄存器地址，这里用 tag 本身）
function _M.get_reg_by_tag(dev_id, tag)
    local dev = cache[dev_id]
    if dev and dev[tag] then
        return tag
    end
    return nil
end

-- down.lua 调用：按 tag 找内部 slot（只读缓存，返回 nil 表示"不支持"）
function _M.get_slot_by_tag(dev_id, tag)
    return nil, _M.ERR_NOT_SUPPORTED
end

-- down.lua 调用：写点位（单板 EPM 是监听-only，不支持下发写入）
-- 留接口口子，以后加 Modbus 写穿透时在这里实现
function _M.set_by_tag(dev_id, tag, num_val)
    return false, _M.ERR_NOT_SUPPORTED
end

-- ============================================================
-- 对齐二合一 report.lua 接口：按点位聚合
-- 返回格式与二合一 store.get_point_values() 完全对齐
-- 但 tag/value 类型不同（二合一用数字地址和 values 数组，这里用字符串 tag）
-- ============================================================
function _M.get_point_values()
    local result = {}
    for unit_id, dev in pairs(cache) do
        for tag, slot in pairs(dev) do
            result[#result + 1] = {
                tag       = tag,
                dev_id    = unit_id,
                values    = { slot.value },   -- 对齐二合一：数组形式
                errcode   = slot.errcode,
                ts        = slot.ts,
                -- 以下字段二合一有，这里填占位，report.lua 不会访问它们
                reg_type     = 4,    -- 4=输入寄存器（只读，XYE 监听就是只读）
                reg_count    = 1,
                data_type    = "int",
                scale_factor = 1,
                bits         = nil,
            }
        end
    end
    return result
end

return _M
