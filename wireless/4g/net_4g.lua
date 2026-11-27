--[[
@module  net_4g
@summary 4G 蜂窝网络管理模块
@version 1.0
@date    2026.11.12
@usage
本文件负责 4G 蜂窝网络的初始化与状态监控：

1. 设置 SIM 通道（贴片卡接 SIM2 / GPIO 模拟通道）
2. 监听 SIM_IND，打印 SIM 卡状态变化
3. 监听 IP_READY，设置自定义 DNS 并打印本机 IP
4. 监听 IP_LOSE，打印断网警告
5. 延时统一打印 IMEI / IMSI / ICCID

所有参数直接写死在文件内，不依赖 config。
]]

-- ============================================================
-- 配置项（写死，不走 config）
-- ============================================================
local SIM_CHANNEL        = 1                       -- 0=SIM1  1=SIM2(GPIO 模拟，贴片卡接在此)
local SIM_INFO_DELAY_MS  = 2000                    -- 上电后延时多久打印 SIM 信息
local DNS_PRIMARY        = "223.5.5.5"            -- 阿里云 DNS
local DNS_SECONDARY      = "114.114.114.114"      -- 国内通用 DNS

-- ============================================================
-- 设备信息
-- ============================================================
-- IMEI / IMSI / ICCID 在 SIM 就绪后统一打印（见下方延时任务）

-- ============================================================
-- SIM 卡初始化
-- ============================================================
mobile.simid(SIM_CHANNEL)

-- ============================================================
-- SIM 状态监听
-- ============================================================
sys.subscribe("SIM_IND", function(status)
    log.info("SIM", "状态: ", status, "当前SIM通道: ", mobile.simid())
end)

-- 延时后统一打印设备标识（IMEI / IMSI / ICCID）
sys.taskInit(function()
    sys.wait(SIM_INFO_DELAY_MS)

    local imei  = (mobile and mobile.imei()) or "无"
    local imsi  = mobile.imsi() or "无"
    local iccid = mobile.iccid() or "无"

    log.error("SIM", "====================================================")
    log.error("SIM", "====================================================")
    log.error("SIM", "当前SIM通道: " .. mobile.simid())
    log.error("SIM", "IMEI: " .. imei)
    log.error("SIM", "IMSI: " .. imsi)
    log.error("SIM", "ICCID: " .. iccid)
    log.error("SIM", "====================================================")
    log.error("SIM", "====================================================")
end)

-- ============================================================
-- IP 状态监听 + DNS 设置
-- ============================================================
-- 在 Air780EPM 上，内核固件运行起来之后，默认网卡就是 socket.LWIP_GP

local function ip_ready_func(ip, adapter)
    if adapter == socket.LWIP_GP then
        -- 在位置 1、2 设置自定义 DNS 服务器：
        -- 自动获取的 DNS 不稳定时，这两个 DNS 会让解析更稳定。
        -- 注意：专网卡或国外网络请勿设置。
        socket.setDNS(adapter, 1, DNS_PRIMARY)
        socket.setDNS(adapter, 2, DNS_SECONDARY)

        log.info("net_4g", "IP_READY: ", socket.localIP(socket.LWIP_GP))
    end
end

local function ip_lose_func(adapter)
    if adapter == socket.LWIP_GP then
        log.warn("net_4g", "IP_LOSE")
    end
end

sys.subscribe("IP_READY", ip_ready_func)
sys.subscribe("IP_LOSE", ip_lose_func)
