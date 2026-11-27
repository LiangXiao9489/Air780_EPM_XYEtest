--[[
@module  config
@summary 运行时配置（JSON 文件持久化，单板 EPM）
@version 1.0
@date    2026.11.27
@usage
所有"运行时可配置"的参数集中管理，文件系统落盘，重启不丢失。

文件位置：/gateway_cfg.json
首次启动：文件不存在 → 写入默认值
后续启动：文件存在 → 读入内存；OTA 新增字段时 get() 自动 fallback 默认值

对外 API：
  get(key)              读参数，文件缺这个 key 时 fallback 默认值
  set(key, val)         改内存 + 立刻落盘
  all()                 返回当前内存中的完整 cfg table（只读）
  defaults()            返回默认值表（调试用）
  factory_reset()       删除配置文件 + 重启
]]

local _M = {}

-- ============================================================
-- 文件路径
-- ============================================================
local CONFIG_PATH = "/gateway_cfg.json"

-- ============================================================
-- 默认参数（写死，单板 EPM）
-- ============================================================
local DEFAULT_CFG = {
    -- 串口参数（XYE 总线，固定 4800 8N1，运行时也能改，但一般不改）
    u1_baudrate = 4800,
    u1_databits = 8,
    u1_stopbits = 1,
    u1_parity   = "N",

    -- 上报参数
    upload_interval_min  = 5,    -- MQTT 整点上报间隔（分钟）
    change_check_sec     = 5,    -- 变化数据检测周期（秒）

    -- 主动上行开关（默认关闭，由平台下发开启）
    report_real_enable   = true,
    report_change_enable = false,

    -- 写使能（MQTT 下发写点位闸门，暂保留口子）
    write_through_en     = true,
}

-- 内存镜像
local cfg

-- ============================================================
-- 内部：落盘
-- ============================================================
local function save()
    local f = io.open(CONFIG_PATH, "w")
    if f then
        f:write(json.encode(cfg))
        f:close()
    else
        log.error("config", "写入失败，磁盘可能满了")
    end
end

-- ============================================================
-- 内部：从文件读或写默认
-- ============================================================
local function load_or_init()
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        cfg = json.decode(raw)
        if type(cfg) ~= "table" then
            log.warn("config", "文件损坏，用默认值覆盖")
            cfg = {}
            save()
        end
    else
        log.info("config", "首次启动，写入默认配置")
        cfg = {}
        for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end
        save()
    end
end

-- ============================================================
-- 对外 API
-- ============================================================

-- 读参数：文件里有就用文件的，没有就 fallback 默认值
function _M.get(key)
    local v = cfg[key]
    if v == nil then
        return DEFAULT_CFG[key]
    end
    return v
end

-- 写参数：改内存 + 立刻落盘
function _M.set(key, val)
    cfg[key] = val
    save()
end

-- 返回完整内存表（调用方只读，别改）
function _M.all()
    return cfg
end

-- 读本板默认表（调试用）
function _M.defaults()
    return DEFAULT_CFG
end

-- 恢复出厂：清空内存配置 → 删除文件 → 重启
function _M.factory_reset()
    log.warn("config", "恢复出厂设置！")
    cfg = {}
    os.remove(CONFIG_PATH)
    log.info("config", "配置文件已删除，即将重启...")
    rtos.reboot()
end

-- ============================================================
-- 模块加载时自动 init（require "config" 即运行）
-- ============================================================
load_or_init()
log.info("config", "初始化完成 文件=" .. CONFIG_PATH)

return _M
