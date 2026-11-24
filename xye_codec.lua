--[[
@module  xye_codec
@summary XYE 协议拆帧 + 校验 + 帧识别 + 已知字段解码
@version 1.0
@date    2026.11.24
@usage   纯函数模块，不依赖任何硬件或其他模块。
         local codec = require "xye_codec"
         local frames, remaining = codec.try_decode(raw_bytes)

帧格式（实测 + HomeOps 文档）：
  轮询帧  16B  AA C0/C1 <dest_id> 00 80 ... <complement> <crc> 55
  C0应答  32B  AA C0 80 00 <src_id> 00 E0 14 <fields 24B> <crc> 55
  C1应答  30B  AA C1 80 00 <src_id> 00 <status 22B> <crc> 55
  AA短帧  10B  AA <cmd> <payload 6B> <crc> 55

校验算法（两套数学等价，实现版本 A）：
  A) 1.md 现场验证版: sum(AA ... CRC) & 0xFF == 0xAA
  B) HomeOps 文档版 : CRC == 0xFF - (sum(AA..55跳过CRC) & 0xFF)
  数学等价: 因为 sum(A..55跳过CRC) + CRC ≡ 0xFF (mod 256)
           所以 0xFF - sumB = CRC ⇔ sumA ≡ 0xAA (mod 256)
]]

local _M = {}

-- 常量
local PREAMBLE      = 0xAA
local PROLOGUE      = 0x55
local MAX_FRAME_LEN = 32   -- XYE 最长帧 32 字节（C0 应答）

-- ============================================================
-- 校验：版本 A（更简洁，已用 10256 帧验证）
-- ============================================================
-- 版本 A 实现: sum(AA ... CRC) & 0xFF == 0xAA（不含末尾 0x55）
-- 与 HomeOps 版本 B 数学等价，实测 4 帧全部通过
local function checksum_ok(raw)
    local sum = 0
    for i = 1, #raw - 1 do    -- 不含最后那个 0x55
        sum = sum + raw:byte(i)
    end
    return (sum & 0xFF) == 0xAA
end

-- ============================================================
-- 帧类型识别（长度是最可靠的区分特征）
-- ============================================================
local function identify_frame(raw)
    local len = #raw
    local cmd = raw:byte(2)   -- byte[1] (0-indexed) = command byte

    if len == 10 then
        return "AA"              -- 广播短帧（主站发）
    elseif len == 16 then
        -- 16 字节 = 主站轮询/设置命令
        if cmd == 0xC0 then return "C0_POLL" end
        if cmd == 0xC1 then return "C1_POLL" end
        if cmd == 0xC3 then return "C3_SET" end
        if cmd == 0xC4 then return "C4_QUERY_EXT" end
        if cmd == 0xC6 then return "C6_FOLLOW_ME" end
        if cmd == 0xCC then return "CC_LOCK" end
        if cmd == 0xCD then return "CD_UNLOCK" end
        return "UNKNOWN_16"
    elseif len == 32 then
        -- 32 字节 = C0 应答 或 C1 应答（现场实测同长，与 1.md 的 30B 说法不符）
        if cmd == 0xC0 then return "C0_RESP" end
        if cmd == 0xC1 then return "C1_RESP" end
        return "UNKNOWN_32"
    elseif len == 30 then
        -- 理论上的 30 字节 C1 应答（1.md 描述，现场样例是 32B，此分支备用）
        if cmd == 0xC1 then return "C1_RESP" end
        return "UNKNOWN_30"
    end
    return "UNKNOWN_" .. len
end

-- ============================================================
-- 提取 unit_id（从设备地址）
--   轮询帧: byte[2] (0-indexed) = 目标设备 ID
--   应答帧: byte[4] (0-indexed) = 源设备 ID（应答方）
--   AA短帧: 无明确 unit_id，返回 nil
-- ============================================================
local function get_unit_id(raw, ftype)
    if ftype == "C0_POLL" or ftype == "C1_POLL" then
        return raw:byte(3)     -- byte[2] = dest_id
    elseif ftype == "C0_RESP" or ftype == "C1_RESP" then
        return raw:byte(5)     -- byte[4] = src_id
    end
    return nil
end

-- ============================================================
-- 温度解码: (raw - 0x28) / 2.0
-- 0xFF 为 sentinel（不可用），返回 nil
-- ============================================================
local function decode_temp(b)
    if b == 0xFF then return nil end
    return (b - 0x28) / 2.0
end

-- ============================================================
-- Target temp 特殊处理: byte6 (0x40) 是状态位要清掉
-- ============================================================
local function decode_target_temp(b)
    if b == 0xFF then return nil end
    b = b & 0xBF               -- 清 bit6 状态位
    return (b - 0x28) / 2.0
end

-- ============================================================
-- Timer flags 解码: bitmask → 小时数（HomeOps Timer Flags）
--   0x01=15min 0x02=30min 0x04=1h 0x08=2h 0x10=4h 0x20=8h 0x40=16h 0x80=无效
-- ============================================================
local function decode_timer(b)
    if b == 0x80 or b == 0x00 then return nil end
    local t = 0
    local map = { [0x01] = 0.25, [0x02] = 0.5, [0x04] = 1, [0x08] = 2,
                  [0x10] = 4, [0x20] = 8, [0x40] = 16 }
    for flag, hours in pairs(map) do
        if (b & flag) ~= 0 then t = t + hours end
    end
    return t
end

-- ============================================================
-- C0 应答 32 字节字段解码（HomeOps PROTOCOL.md Receive Messages）
-- byte 偏移全部 1-indexed（Lua string.byte 从 1 开始）
--
-- 全字段清单（按 offset 顺序）:
--   byte1=AA(帧头)  byte2=cmd  byte3=dir(0x00或0x80)  byte4=dest_id
--   byte5=src_id  byte6=dest_id(重复)  byte7=Unknown1(capability related)
--   byte8=Capabilities  byte9=op_mode  byte10=fan_mode
--   byte11=target_temp(含bit6状态位)  byte12=T1室内  byte13=T2盘管
--   byte14=T2B盘管排  byte15=T3室外  byte16=电流(常0xFF)
--   byte17=Unknown2  byte18=Timer Start  byte19=Timer Stop
--   byte20=压缩机运行标志  byte21=ModeFlags  byte22=OperationFlags
--   byte23=E1故障码  byte24=E2故障码  byte25=保护状态低(0x02=DEFROST)
--   byte26=保护状态高  byte27=CCM通信错误
--   byte28-29=未知(候选EEV 16-bit LE步数)  byte30=未知  byte31=CRC  byte32=0x55
-- ============================================================
local function decode_c0_fields(raw)
    return {
        -- === 头部（byte1~byte6 已被 codec 提取为 ftype/unit_id，这里不解） ===

        -- byte7: Unknown1 (HomeOps: 可能 0x30 capability related)
        unknown_1 = raw:byte(7),

        -- byte8: Capabilities (HomeOps: 0x80=EXTERNAL_TEMP, 0x10=SWING)
        caps        = raw:byte(8),
        caps_sw     = (raw:byte(8) & 0x10) ~= 0,   -- 支持摆风
        caps_extemp = (raw:byte(8) & 0x80) ~= 0,   -- 支持 Follow-Me

        -- byte9: operation_mode
        op_mode = raw:byte(9),

        -- byte10: fan_mode (bit7=AUTO, low4=实际速度)
        fan_mode   = raw:byte(10),
        fan_auto   = (raw:byte(10) & 0x80) ~= 0,
        fan_speed  = raw:byte(10) & 0x0F,

        -- byte11: target_temp (含 bit6=0x40 状态位)
        target_temp_raw = raw:byte(11),
        target_temp     = decode_target_temp(raw:byte(11)),

        -- byte12~15: 温度传感器
        t1_temp  = decode_temp(raw:byte(12)),
        t2_temp  = decode_temp(raw:byte(13)),
        t2b_temp = decode_temp(raw:byte(14)),
        t3_temp  = decode_temp(raw:byte(15)),

        -- byte16: 电流（常为 0xFF，IDU 侧不量电流）
        current = raw:byte(16),

        -- byte17: Unknown2
        unknown_2 = raw:byte(17),

        -- byte18~19: Timer Start / Stop（bitmask → 小时数）
        timer_start     = raw:byte(18),
        timer_start_h   = decode_timer(raw:byte(18)),
        timer_stop      = raw:byte(19),
        timer_stop_h    = decode_timer(raw:byte(19)),

        -- byte20: 压缩机运行标志（0x01=run 现场观察性结论）
        compressor_run = raw:byte(20),

        -- byte21: Mode Flags
        mode_flags = raw:byte(21),
        mode_eco   = (raw:byte(21) & 0x01) ~= 0,
        mode_aux   = (raw:byte(21) & 0x02) ~= 0,
        mode_swing = (raw:byte(21) & 0x04) ~= 0,

        -- byte22: Operation Flags
        op_flags      = raw:byte(22),
        op_waterpump  = (raw:byte(22) & 0x04) ~= 0,
        op_waterlock  = (raw:byte(22) & 0x80) ~= 0,

        -- byte23~24: 故障码
        err_flags_low  = raw:byte(23),
        err_flags_high = raw:byte(24),

        -- byte25~26: 保护状态
        prot_flags_low  = raw:byte(25),
        prot_flags_high = raw:byte(26),
        prot_defrost    = (raw:byte(25) & 0x02) ~= 0,   -- 已知 0x02=正在除霜

        -- byte27: CCM 通信错误标志
        ccm_err = raw:byte(27),

        -- byte28~30: 未知（候选 EEV 位置: byte28 低 + byte29 高 = 16-bit LE）
        byte28 = raw:byte(28),
        byte29 = raw:byte(29),
        byte30 = raw:byte(30),
        -- 候选 EEV 步数（如果这两个字节真是 EEV）
        eev_steps = raw:byte(28) | (raw:byte(29) << 8),
    }
end

-- ============================================================
-- 主拆帧函数
--   buffer: 累计的字节串（可能含 FE 前导、多帧、噪声）
--   返回: frames (数组), remaining (未消费的尾部字节)
-- ============================================================
function _M.try_decode(buffer)
    local frames = {}
    local pos = 1

    while pos <= #buffer do
        -- 找 AA 起点（跳过 FE 和噪声）
        local aa_pos = string.find(buffer, string.char(PREAMBLE), pos, true)
        if not aa_pos then
            -- 后面没有 AA 了，丢弃所有剩余噪声
            break
        end

        -- 从 AA 起找 55 终点，最多扫 MAX_FRAME_LEN 字节
        local tail_pos = string.find(buffer, string.char(PROLOGUE), aa_pos + 1, true)

        if not tail_pos or tail_pos > aa_pos + MAX_FRAME_LEN - 1 then
            -- 找不到 55，或者 55 太远（不可能是有效 XYE 帧）
            -- 截断 AA 之前的噪声，保留 AA 及之后等下次追加
            if aa_pos > pos then
                buffer = buffer:sub(aa_pos)
            end
            break
        end

        -- 切出 AA..55
        local raw = buffer:sub(aa_pos, tail_pos)

        -- 校验
        if checksum_ok(raw) then
            local ftype   = identify_frame(raw)
            local unit_id = get_unit_id(raw, ftype)

            local frame = {
                ftype   = ftype,
                unit_id = unit_id,
                len     = #raw,
                raw     = raw,
            }

            -- 目前只解码 C0 应答字段
            if ftype == "C0_RESP" then
                frame.fields = decode_c0_fields(raw)
            end

            frames[#frames + 1] = frame
        end
        -- 校验失败静默丢弃（不计数、不回调），现场 P1 阶段先不关心噪声来源

        pos = tail_pos + 1
    end

    local remaining = buffer:sub(pos)
    return frames, remaining
end

-- ============================================================
-- 辅助: 字节串 → 空格分隔的 HEX 字符串（用于日志）
-- ============================================================
function _M.to_hex(raw)
    local parts = {}
    for i = 1, #raw do
        parts[#parts + 1] = string.format("%02X", raw:byte(i))
    end
    return table.concat(parts, " ")
end

return _M
