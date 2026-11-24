

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


-- ========== 临时 codec 单测 ==========
local codec = require "xye_codec"

local c0_poll_hex = "AA C0 08 00 80 00 00 00 00 00 00 00 00 3F 79 55"
local c0_resp_hex = "AA C0 80 00 08 00 E0 14 A8 04 19 58 3A 3A FF FF 00 00 00 01 00 14 00 00 00 00 00 14 FF FF 0E 55"
local c1_poll_hex = "AA C1 08 00 80 00 00 00 00 00 00 00 00 3E 79 55"
local c1_resp_hex = "AA C1 80 00 08 00 14 FF 13 FF 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 14 FF FF 80 55"

local function hex_to_bin(s)
    local s2 = s:gsub("%s+", "")
    local out = ""
    for i = 1, #s2, 2 do
        out = out .. string.char(tonumber(s2:sub(i, i+1), 16))
    end
    return out
end

local test_data = hex_to_bin(c0_poll_hex .. c0_resp_hex .. c1_poll_hex .. c1_resp_hex)

log.error("TEST", "========== codec 单测开始 ==========")
local frames, remain = codec.try_decode(test_data)
log.error("TEST", "解出 " .. #frames .. " 帧, 剩余 " .. #remain .. " 字节")

for i, f in ipairs(frames) do
    log.error("TEST", string.format("[%d] ftype=%-12s unit_id=%s len=%d",
        i, f.ftype, tostring(f.unit_id), f.len))
    if f.fields then
        local flds = f.fields
        log.error("TEST", string.format("    op_mode=0x%02X fan_mode=0x%02X",
            flds.op_mode, flds.fan_mode))
        log.error("TEST", string.format("    t1=%.1f t2=%.1f t2b=%.1f t3=%s",
            flds.t1_temp or -99, flds.t2_temp or -99, flds.t2b_temp or -99,
            tostring(flds.t3_temp)))
        log.error("TEST", string.format("    compressor=%d err_lo=0x%02X prot_lo=0x%02X",
            flds.compressor_run, flds.err_flags_low, flds.prot_flags_low))
    end
end
log.error("TEST", "========== codec 单测结束 ==========")
-- ========== 临时 codec 单测结束 ==========

sys.run()
