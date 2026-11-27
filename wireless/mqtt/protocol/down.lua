--[[
@module  down
@summary MQTT 下行 JSON 解析 + 按 topic/type 分发（唯一入口：dispatch）
@version 2.0
@date    2026.11.18
@usage
receiver.lua 在 "recv" 事件回调里拿到 topic 和 payload 后，
只需要调一行 down.dispatch(topic, payload)，down 内部会：
  1. 按 topic 找到对应的 handler 表
  2. json.decode payload 得到 msg
  3. 按 msg.t 找到对应的 type handler
  4. handler 回调里 sys.taskInit 独立 task 处理（不阻塞 receiver 回调）

三个下行 topic 各自的 type：
  /s/${sn}    → call（查询缓存）、set（下发写入）
  /scr/${sn}  → indexReal（已实现）、his / ctr（暂只打日志）
  /s2/${sn}   → call（读网关参数）、set（改网关参数）、ota（远程升级）

与 EPM 原工程的差异：
  1. set 不再直接操作 485，统一走 store.set_by_tag；
     具体落到"485 写穿透"还是"本机 DO"，由各板注册的 writer 决定
     （EPM = write_through，EHV = do_write），本文件完全不区分板型；
  2. call 的 ts 为空/缺省时返回该设备的全部点位（两板行为一致）；
  3. /s2 的参数白名单由 cfg.lua 按板型裁剪（EHV 没有 u1_*）。

handler 回调签名：function(msg)  msg 是 decode 后的完整表
]]

local topics = require "topics"
local store  = require "store"
local up     = require "up"
local ack    = require "ack"
local sender = require "sender"
local report = require "report"
local cfg    = require "cfg"
local ota    = require "ota"
local board  = nil  -- 单板 EPM，已在 cfg.lua 里简化
local config = require "config"

local down = {}

-- ============================================================
-- 工具函数
-- ============================================================

-- 获取当前时间字符串 "2018-10-10 16:01:47"
local function now_str()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- 检查 store 是否就绪（按需建点位模式下，就绪时可能还没有任何设备数据）
local function store_ready()
    return store.is_ready()
end

-- JSON 对象的 key 永远是字符串（{"240":{...}}），而 point_table 里的 dev_id 是数字
-- 查 store 前必须归一化，否则 regs_by_tag["1"] 取不到 regs_by_tag[1]
-- 回包时仍用原始 key，保证和服务端下发的一致
local function norm_dev(dev_id)
    local n = tonumber(dev_id)
    return n or dev_id
end

-- ============================================================
-- handler 注册表：每个下行 topic 一张表，key = type, value = 回调
-- handler 回调里用 sys.taskInit 起独立 task，不阻塞 receiver
-- ============================================================
local TOPIC_HANDLERS = {
    -- /s/${sn}：主业务下行
    [topics.SUB_DATA] = {
        -- call 查询缓存：
        -- 下行: { t:"call", d:{ dev_id:{ ts:{tag1, tag2}, mid:1234 } } }
        --       ts 缺省或空数组 → 返回该设备全部点位
        -- 上行: { t:"callack", ti:"...", d:{ dev_id:{ tag1:{q,t,v}, mid } } }
        call = function(msg)
            sys.taskInit(function()
                if not store_ready() then
                    log.warn("mqtt.down", "call store 未就绪")
                    return
                end

                for dev_id, body in pairs(msg.d or {}) do
                    local did = norm_dev(dev_id)
                    local mid = body.mid
                    local result = {}

                    local ts = body.ts or {}
                    if #ts == 0 then
                        -- 空表全量：按设备列出点表里全部 tag
                        for _, p in ipairs(store.get_point_values()) do
                            if p.dev_id == did then
                                ts[#ts + 1] = p.tag
                            end
                        end
                        log.info("mqtt.down", "call 空 ts，返回全量",
                                 "dev=" .. tostring(dev_id), "count=" .. #ts)
                    end

                    for _, tag in ipairs(ts) do
                        local slot = store.get_slot_by_tag(did, tag)
                        if not slot then
                            log.warn("mqtt.down", "call tag 不存在", dev_id, tag)
                            -- 协议：q 是质量位 0/1，拿不到点位按质量差处理
                            result[tag] = { q = "0", t = tostring(os.time()), v = "0" }
                        else
                            local slot_ts = slot.ts
                            if not slot_ts or slot_ts == 0 then slot_ts = os.time() end
                            result[tag] = {
                                q = (slot.errcode == 0) and "1" or "0",
                                t = tostring(slot_ts),
                                v = tostring(slot.data or 0),
                            }
                        end
                    end

                    -- 协议：mid 放在设备对象里，和 tag 平级
                    if mid ~= nil then result.mid = mid end

                    local payload = up.with_time("callack", now_str(), { [dev_id] = result })
                    sender.publish(topics.UP_DATA, payload, 1)
                end
            end)
        end,

        -- set 下发写入：
        -- 下行: { t:"set", d:{ dev_id:{ tag1:val1, tag2:val2, mid:1234 } } }
        -- 上行: { t:"setack", d:{ dev_id:{ r:{success:"all"} 或 {fail:[...],not_found:[...]}, mid } } }
        set = function(msg)
            sys.taskInit(function()
                if not store_ready() then
                    log.warn("mqtt.down", "set store 未就绪")
                    return
                end

                -- 写使能闸门（单板 EPM，暂不支持 MQTT 下发写点位）
                local enable_key = "write_through_en"
                if config.get(enable_key) ~= true then
                    log.warn("mqtt.down", "set 被禁止", enable_key .. "=false")
                    for dev_id, body in pairs(msg.d or {}) do
                        sender.publish(topics.UP_DATA,
                            ack.build("setack", dev_id, { fail = { "disabled" } }, body.mid), 1)
                    end
                    return
                end

                local any_written = false

                for dev_id, body in pairs(msg.d or {}) do
                    local did = norm_dev(dev_id)
                    local mid = body.mid
                    local fail_tags = {}
                    local not_found_tags = {}
                    local all_ok = true

                    for tag, val in pairs(body) do
                        if tag ~= "mid" then
                            local num_val = tonumber(val)
                            local why

                            if num_val == nil then
                                why = "值非法"
                                all_ok = false
                                fail_tags[#fail_tags + 1] = tag
                            else
                                -- 板型差异在这里被完全屏蔽：
                                -- EPM 落到 485 写穿透，EHV 落到本机 DO
                                local ok, reason = store.set_by_tag(did, tag, num_val)
                                if ok then
                                    any_written = true
                                elseif reason == store.ERR_NOT_FOUND then
                                    all_ok = false
                                    not_found_tags[#not_found_tags + 1] = tag
                                    why = "tag 不存在"
                                else
                                    all_ok = false
                                    fail_tags[#fail_tags + 1] = tag
                                    why = tostring(reason)
                                end
                            end

                            if why then
                                log.warn("mqtt.down", "set 未写入", dev_id, tag,
                                         tostring(val), why)
                            end
                        end
                    end

                    local result
                    if all_ok then
                        result = { success = "all" }
                    else
                        -- 空数组不要带出去：Lua 空表 json.encode 成 {}，服务端按数组解析会出错
                        result = {}
                        if #fail_tags > 0 then result.fail = fail_tags end
                        if #not_found_tags > 0 then result.not_found = not_found_tags end
                    end
                    sender.publish(topics.UP_DATA,
                        ack.build("setack", dev_id, result, mid), 1)
                end

                -- 协议 2.4 注：写入成功后 iot 不会改自己的实时数据，需要补一条 real。
                -- 全部失败时原值没变，不需要补。
                if any_written then
                    report.send_real_after_set()
                end
            end)
        end,
    },

    -- /scr/${sn}：控制下行
    [topics.SUB_CONTROL] = {
        -- 首页实时数据快速上传：立即上报一次，之后按 iv 周期上报，du 秒后恢复
        indexReal = function(msg)
            log.info("mqtt.down", "indexReal 快速上传",
                     "sti=" .. tostring(msg.sti),
                     "du=" .. tostring(msg.du),
                     "iv=" .. tostring(msg.iv))
            report.start_index_real(msg)
        end,

        his = function(msg)
            log.info("mqtt.down", "his 历史召回（暂未实现）", json.encode(msg.d))
        end,

        ctr = function(msg)
            log.info("mqtt.down", "ctr 控制（暂未实现）", json.encode(msg.d))
        end,
    },

    -- /s2/${sn}：网关自身参数（把网关当成一台虚拟设备，UID 作为设备 id）
    -- 与设备 call/set 结构完全一致，只是网关内部改为读写 config 而不是点位
    [topics.SUB_CFG] = {
        call = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if tostring(dev_id) == topics.SN then
                        cfg.on_call(dev_id, body)
                    else
                        log.warn("mqtt.down", "cfg topic 设备号不是本机", dev_id,
                                 "sn=" .. topics.SN)
                    end
                end
            end)
        end,

        set = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if tostring(dev_id) ~= topics.SN then
                        log.warn("mqtt.down", "cfg topic 设备号不是本机", dev_id,
                                 "sn=" .. topics.SN)
                    elseif ota.is_busy() and body.sys_action then
                        -- OTA 升级中拦截 reboot/factoryReset，避免把升级打断
                        log.warn("mqtt.down", "OTA 升级中，拦截 sys_action")
                        sender.publish(topics.UP_CFG,
                            ack.build("setack", topics.SN, { fail = { "busy" } }, body.mid), 1)
                        cfg.set_last_error("ota_busy")
                    else
                        cfg.on_set(dev_id, body)
                    end
                end
            end)
        end,

        -- OTA 升级：{"t":"ota","d":{"${sn}":{"url":"...","crc":"...","size":"...","mid":1}}}
        -- ack 分两阶段：otaDownloadAck（下载/校验阶段）+ otaVerifyAck（CRC 校验阶段）
        ota = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if tostring(dev_id) == topics.SN then
                        ota.on_ota(body)
                    else
                        log.warn("mqtt.down", "ota topic 设备号不是本机", dev_id,
                                 "sn=" .. topics.SN)
                        cfg.set_last_error("ota_param")
                        sender.publish(topics.UP_CFG,
                            ack.build("otaDownloadAck", topics.SN,
                                      { fail = { "param" } }, body and body.mid), 1)
                    end
                end
            end)
        end,
    },
}

-- ============================================================
-- 对外唯一入口
-- ============================================================
function down.dispatch(topic, payload)
    -- 1. 按 topic 找 handler 表
    local handlers = TOPIC_HANDLERS[topic]
    if not handlers then
        log.warn("mqtt.down", "无 handler 的 topic", topic)
        return false
    end

    -- 2. json.decode
    local ok, msg = pcall(json.decode, payload)
    if not ok or type(msg) ~= "table" then
        log.warn("mqtt.down", "json decode 失败", payload)
        return false
    end

    -- 3. 按 type 找 handler
    local handler = handlers[msg.t]
    if not handler then
        log.warn("mqtt.down", "未知 type", msg.t, "topic=" .. tostring(topic))
        return false
    end

    -- 4. 执行 handler（handler 里自己起独立 task，这里同步调用完就返回）
    handler(msg)
    return true
end

return down
