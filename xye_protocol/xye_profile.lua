-- ============================================================
-- xye_profile.lua —— XYE 点位 / Modbus 地址映射表（纯数据 + 纯函数）
--
-- 职责：把 codec 解码出的字段，映射成 Modbus 点位
--       · 离散输入 DI (Discrete Input, 1 bit, 只读)
--       · 输入寄存器 IR (Input Register, 16 bit, 只读)
--
-- 点表划分（依据现场实测结论）：
--   · unit_points   每台内机独立点位 —— 11 台各建一套
--   · system_points 全系统共享点位   —— 只建一份（取自任一在线内机的 C0 帧）
--
-- 地址规则：
--   DI 地址 = unit_index * DI_STRIDE + 点内偏移
--   IR 地址 = unit_index * IR_STRIDE + 点内偏移
--   系统点位排在全部内机点位之后
--
-- 本文件不 require 任何硬件或网关模块，可整体移植。
-- ============================================================

local M = {}

-- 已知内机 unit_id（顺序固定，决定地址分配；与现场 11 台一致）
local UNIT_ORDER = { 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x28, 0x29, 0x2A }
local UNIT_INDEX = {}
for i, id in ipairs(UNIT_ORDER) do UNIT_INDEX[id] = i - 1 end

M.UNIT_ORDER = UNIT_ORDER
M.UNIT_INDEX = UNIT_INDEX
M.UNIT_COUNT = #UNIT_ORDER

-- ============================================================
-- 每台内机的点位定义
--
-- 【地址计算公式】
--   实际地址 = 该设备起始地址 + 段内偏移
--
-- 【各设备起始地址（IR_STRIDE=11 / DI_STRIDE=4）】
--   unit     IR 起始     DI 起始
--   0x08     0x0000      0x0000
--   0x09     0x000B      0x0004
--   0x0A     0x0016      0x0008
--   0x0B     0x0021      0x000C
--   0x0C     0x002C      0x0010
--   0x0D     0x0037      0x0014
--   0x0E     0x0042      0x0018
--   0x0F     0x004D      0x001C
--   0x28     0x0058      0x0020
--   0x29     0x0063      0x0024
--   0x2A     0x006E      0x0028
--   系统级   0x0079 起   0x002C
--
-- 【段内偏移】（下表每条末尾的 +N 即此值）
--   IR: +0 运行模式  +1 风扇模式  +2 设定温度原始  +3 室内回风
--       +4 盘管温度  +5 盘管排温度  +6 故障标志    +7 保护状态
--       +8 设备固有码 +9 运行态值A  +10 运行态值B
--   DI: +0 水泵运行  +1 ECO节能   +2 电辅热      +3 摆风
--
-- 【举例】0x0A 的"盘管温度" = 0x0016 + 4 = IR 0x001A
--         0x28 的"运行态值B" = 0x0058 + 10 = IR 0x0062
--
-- 注意：偏移由加载期 assign_offsets() 按表中顺序自动分配；
--       增删/重排点位会使后续偏移顺延，务必同步更新上面的地址注释。
-- ============================================================

-- get(fields) 返回点位原始数值；scale 仅用于展示（寄存器值 ÷ scale = 物理量）
-- src: "c0" 取 C0 应答字段 / "c1" 取 C1 应答字段
M.unit_points = {
    -- ===== 输入寄存器 IR =====
    { key = "op_mode",      cn = "运行模式",     kind = "IR", src = "c0",   -- IR+0
      get = function(f) return f.op_mode end },
    { key = "fan_mode",     cn = "风扇模式",     kind = "IR", src = "c0",   -- IR+1
      get = function(f) return f.fan_mode end },
    { key = "set_temp_raw", cn = "设定温度原始", kind = "IR", src = "c0",   -- IR+2
      get = function(f) return f.target_temp_raw end },
    { key = "t1_temp",      cn = "室内回风",     kind = "IR", src = "c0", scale = 10,   -- IR+3
      get = function(f) return f.t1_temp end },
    { key = "t2_temp",      cn = "盘管温度",     kind = "IR", src = "c0", scale = 10,   -- IR+4
      get = function(f) return f.t2_temp end },
    { key = "t2b_temp",     cn = "盘管排温度",   kind = "IR", src = "c0", scale = 10,   -- IR+5
      get = function(f) return f.t2b_temp end },
    { key = "fault",        cn = "故障标志",     kind = "IR", src = "c0",   -- IR+6
      get = function(f) return (f.err_flags_high or 0) * 256 + (f.err_flags_low or 0) end },
    { key = "protect",      cn = "保护状态",     kind = "IR", src = "c0",   -- IR+7
      get = function(f) return (f.prot_flags_high or 0) * 256 + (f.prot_flags_low or 0) end },
    { key = "device_code",  cn = "设备固有码",   kind = "IR", src = "c0",   -- IR+8
      get = function(f) return f.byte28 end },
    { key = "c1_a",         cn = "运行态值A",    kind = "IR", src = "c1",   -- IR+9
      get = function(f) return f.val_a end },
    { key = "c1_b",         cn = "运行态值B",    kind = "IR", src = "c1",   -- IR+10
      get = function(f) return f.val_b end },

    -- ===== 离散输入 DI =====
    { key = "pump",         cn = "水泵运行",     kind = "DI", src = "c0",   -- DI+0
      get = function(f) return f.op_waterpump and 1 or 0 end },
    { key = "eco",          cn = "ECO节能",      kind = "DI", src = "c0",   -- DI+1
      get = function(f) return f.mode_eco and 1 or 0 end },
    { key = "aux",          cn = "电辅热",       kind = "DI", src = "c0",   -- DI+2
      get = function(f) return f.mode_aux and 1 or 0 end },
    { key = "swing",        cn = "摆风",         kind = "DI", src = "c0",   -- DI+3
      get = function(f) return f.mode_swing and 1 or 0 end },
}

-- 系统级共享点位（地址在内机点位之后）
--   compressor_run → DI 0x002C
--   t3_temp        → IR 0x0079
--   ccm_err        → IR 0x007A
M.system_points = {
    { key = "compressor_run", cn = "压缩机运行",  kind = "DI", src = "c0",   -- DI 0x002C
      get = function(f) return (f.compressor_run == 1) and 1 or 0 end },
    { key = "t3_temp",        cn = "室外温度",    kind = "IR", src = "c0", scale = 10,   -- IR 0x0079
      get = function(f) return f.t3_temp end },
    { key = "ccm_err",        cn = "CCM通信错误", kind = "IR", src = "c0",   -- IR 0x007A
      get = function(f) return f.ccm_err end },
}

-- ============================================================
-- 加载期：为每个点位分配偏移 / 绝对地址
-- ============================================================
local function assign_offsets()
    local ir, di = 0, 0
    for _, p in ipairs(M.unit_points) do
        if p.kind == "IR" then
            p.offset = ir
            ir = ir + 1
        else
            p.offset = di
            di = di + 1
        end
    end
    M.IR_STRIDE = ir
    M.DI_STRIDE = di

    -- 系统点位排在全部内机点位之后
    local sir = M.UNIT_COUNT * ir
    local sdi = M.UNIT_COUNT * di
    for _, p in ipairs(M.system_points) do
        if p.kind == "IR" then
            p.abs = sir
            sir = sir + 1
        else
            p.abs = sdi
            sdi = sdi + 1
        end
    end
    M.IR_TOTAL = sir
    M.DI_TOTAL = sdi
end
assign_offsets()

-- ============================================================
-- 对外接口
-- ============================================================

-- 内机点位地址；未知 unit_id 返回 nil
function M.unit_addr(p, unit_id)
    local k = UNIT_INDEX[unit_id]
    if not k then
        return nil
    end
    if p.kind == "IR" then
        return k * M.IR_STRIDE + p.offset
    end
    return k * M.DI_STRIDE + p.offset
end

-- 系统点位地址
function M.sys_addr(p)
    return p.abs
end

-- 取点位应写入寄存器的整数数值
--   DI  → 0 / 1
--   IR  → 按 scale 缩放后取整（无 scale 则原值）
--   nil → 无数据
function M.point_value(p, fields)
    if not fields then
        return nil
    end
    local v = p.get(fields)
    if v == nil then
        return nil
    end
    if p.kind == "DI" then
        return (v ~= 0) and 1 or 0
    end
    if p.scale then
        return math.floor(v * p.scale + 0.5)
    end
    return math.floor(v + 0.5)
end

return M
