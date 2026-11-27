# Air780EPM XYE 总线 IoT 网关

> 在银尔达 Air780EPM 模组上，通过 RS-485 **只读旁听**智谷美的 XYE 空调总线，
> 采集在线室内机运行参数 → 本地缓存 → MQTT 上报云端，支持 OTA 和远程配置。
>
> 当前阶段：**纯只读采集 + 上报**，不向总线发送任何字节，不控制空调。

---

## 目录

- [1. 工程功能](#1-工程功能)
- [2. 硬件与引脚](#2-硬件与引脚)
- [3. 代码结构](#3-代码结构)
- [4. 启动流程](#4-启动流程)
- [5. 数据流](#5-数据流)
- [6. MQTT 协议](#6-mqtt-协议)
- [7. 运行时配置](#7-运行时配置)
- [8. OTA 与状态灯](#8-ota-与状态灯)
- [9. XYE 协议要点](#9-xye-协议要点)
- [10. C0 应答字段解码](#10-c0-应答字段解码)
- [11. C1 / AA 帧说明](#11-c1--aa-帧说明)
- [12. 离线判定](#12-离线判定)
- [13. 为后续扩展预留](#13-为后续扩展预留)
- [14. 已知坑](#14-已知坑)
- [15. 参考资料](#15-参考资料)

---

## 1. 工程功能

| 功能 | 说明 | 状态 |
|---|---|---|
| XYE 旁听 | RS-485 UART1 4800 8N1 只收不发，不影响原有 CCM 主站轮询 | ✅ 已实现 |
| 帧解码 | C0/C1/AA 三类帧拆帧 + CRC 校验 + 字段解码 | ✅ 已实现 |
| 本地缓存 | 所有在线室内机全部参数动态缓存在 RAM，支持离线判定 | ✅ 已实现 |
| 4G 联网 | SIM 卡自动识别，APN 自动获取，IP_READY 事件驱动 | ✅ 已实现 |
| MQTT 上报 | 整点全量 (real) + 变化检测 (change) + 平台触发快速上报 (realIndex) | ✅ 已实现 |
| NTP 对时 | IP_READY 后自动对时，时间有效性门控防止假时间戳上报 | ✅ 已实现 |
| 远程配置 | 平台下发参数 set/get，落盘 `/gateway_cfg.json` 重启不丢 | ✅ 已实现 |
| OTA 升级 | 远程下载固件升级 | ✅ 已实现 |
| NET 状态灯 | GPIO27，MQTT 已连=常亮，离线=快闪 | ✅ 已实现 |
| 恢复出厂 | GPIO30 长按 7 秒，删除配置文件 + 重启 | ✅ 已实现 |
| 硬件看门狗 | GPIO28 连接 Air153C，每 120s 喂一次脉冲 | ✅ 已实现 |

**暂未实现（预留接口）**

- XYE 写入 / 控制室内机（0xC3 SET 帧）
- Modbus 协议转换（tag → s_addr 映射层已预留口子）
- Modbus 从站响应上位机

---

## 2. 硬件与引脚

### 2.1 模组

| 项 | 值 |
|---|---|
| 模组 | 银尔达 Air780EPM（`Air780EPM_A12`） |
| LuaOS 版本 | base 26.04 |

### 2.2 引脚分配

| 引脚 | 功能 | 方向 | 备注 |
|---|---|---|---|
| **UART1 X** | RS-485 A | — | 4800 8N1 半双工 |
| **UART1 Y** | RS-485 B | — | — |
| **UART1 E** | RS-485 GND | — | — |
| **GPIO25** | RS-485 方向控制 | 输出 | 旁听模式固定低电平（只收不发） |
| **GPIO27** | NET LED | 输出 | 高电平亮 |
| **GPIO28** | Air153C 外部看门狗 | 输出 | 每 120s 发 250ms 脉冲 |
| **GPIO30** | 恢复出厂按键 | 输入 | 内部上拉，按下=GND，长按 7s |

### 2.3 接线

```
Air780EPM u1          USB-485 转接器
    X (485 A)   ←→    A
    Y (485 B)   ←→    B
    E (GND)     ←→    GND
```

若不通，先对调 X / Y。

---

## 3. 代码结构

```
main.lua                           启动入口：串起所有模块
net_led.lua                        GPIO27 NET 状态灯（MQTT 连/断 → 常亮/快闪）
reset_btn.lua                      GPIO30 长按 7s 恢复出厂
system/
  config.lua                       运行时配置 JSON 落盘 (/gateway_cfg.json)
  store.lua                        轻量点位缓存（tag 字符串索引，无 Modbus 地址映射）
  ext_wdt.lua                      GPIO28 Air153C 看门狗喂狗（写死引脚）
xye_protocol/
  xye_listener.lua                 UART1 旁听驱动（buffer 管理 + 调 codec）
  xye_codec.lua                    拆帧 + 校验 + 字段解码（纯函数，零硬件依赖）
  xye_bridge.lua                   XYE 帧 → store 缓存 + 离线判定（单板版）
wireless/
  4g/
    net_4g.lua                     SIM 识别 + IP 状态监听 + DNS 设置
    sntp.lua                       NTP 网络对时
    net_watchdog.lua               网络看门狗（可选，当前未启用）
  mqtt/
    basic.lua                      broker.emqx.io 连接 + 自动重连 + 订阅
    sender.lua                     异步发送队列
    receiver.lua                   下行消息入队 + 独立 task 解析
    protocol/
      topics.lua                   MQTT topic 模板（带设备 UID）
      up.lua                       上行报文组装（real/change/realIndex 格式）
      ack.lua                      setack / indexRealAck 等下行应答构建
      report.lua                   定时上报 task（整点 real + 周期 change + 快速上报）
      cfg.lua                      远程配置 set/get 参数白名单 + 校验
      down.lua                     下行指令分发（cfg.set / indexReal / ota 等）
  ota.lua                          OTA 固件升级
.gitignore                         忽略 _extra/、luadb/ 等
```

### 3.1 模块分类

| 层 | 模块 | 说明 |
|---|---|---|
| 入口 | `main.lua` | 唯一的启动顺序编排 |
| 硬件支撑 | `ext_wdt` `net_led` `reset_btn` | 全部写死 EPM 引脚，不做板型切换 |
| 配置 | `system/config.lua` | 单板 EPM，无点表选择、无串口切换 |
| 数据层 | `system/store.lua` | 全工程唯一数据源，所有模块通过它读写点位 |
| 采集层 | `xye_listener` `xye_codec` `xye_bridge` | UART → 字节流 → 帧 → 缓存 |
| 联网层 | `4g/net_4g` `4g/sntp` | SIM → IP → 时间同步 |
| MQTT 核心 | `mqtt/basic` `mqtt/sender` `mqtt/receiver` | 连接 + 队列 + 事件驱动 |
| MQTT 协议 | `mqtt/protocol/*` | topic、payload 格式、指令解析、上报 |
| OTA | `wireless/ota.lua` | 固件升级 |

### 3.2 require 路径

所有模块放在根目录或直接子目录下，用扁平名 require（LuatOS 按脚本名在 luadb 中查找）：

```lua
require "sys"
require "config"          -- system/config.lua
require "store"           -- system/store.lua
require "ext_wdt"         -- system/ext_wdt.lua
require "xye_listener"    -- xye_protocol/xye_listener.lua
require "xye_codec"       -- xye_protocol/xye_codec.lua
require "xye_bridge"      -- xye_protocol/xye_bridge.lua
require "net_4g"          -- wireless/4g/net_4g.lua
require "sntp"            -- wireless/4g/sntp.lua
require "basic"           -- wireless/mqtt/basic.lua（basic 内部自动 require sender/receiver/topics/down/report/cfg/ota）
require "net_led"         -- net_led.lua（根目录）
require "reset_btn"       -- reset_btn.lua（根目录）
```

---

## 4. 启动流程

```
sys 内核初始化
  │
  ├─ pm.ioVol(3300)
  │
  ├─ config.load_or_init()          ← 读 /gateway_cfg.json，没有则写默认值
  ├─ store.init()                    ← 空初始化，等 XYE 帧到了再 ensure_device
  │
  ├─ ext_wdt 喂狗 task 自启
  │
  ├─ xye_listener.init()             ← UART1 4800 8N1 + en_pin=25
  ├─ xye_bridge.start()              ← 离线判定 task 自启
  │
  ├─ net_4g 自启                     ← SIM RDY 监听 + IP_READY 监听
  ├─ sntp 自启                       ← 等 IP_READY 后对时
  ├─ basic 自启                      ← 等 IP_READY 后连 broker.emqx.io
  │     └─ 内部自动 require:
  │          receiver（下行队列 task）
  │          sender（发送队列 task）
  │          topics（topic 模板）
  │          down（下行指令分发）
  │          cfg（远程配置）
  │          report（定时上报 task）
  │          ota（OTA 注册）
  │
  ├─ net_led task 自启               ← 订阅 MQTT_CONNECTED / DISCONNECTED
  ├─ reset_btn task 自启             ← 100ms 采样 GPIO30
  │
  ├─ 5s 统计定时器                   ← 总帧数 / 在线设备 / store 缓存数
  │
  └─ sys.run()
```

---

## 5. 数据流

```
┌─────────── UART1 4800 8N1 ───────────┐
│                                       │
│  CCM 主站轮询 XYE 总线                │
│  (listener 只收不发，方向脚固定低)     │
│                                       │
└───────────────┬───────────────────────┘
                │ 字节流
                ▼
┌──────────────────────────────┐
│ xye_listener.lua             │
│ buffer 管理 + try_decode()   │
└──────────────┬───────────────┘
               │ frames[]
               ▼
┌──────────────────────────────┐
│ xye_codec.lua                │
│ CRC 校验 → 识别 ftype +      │
│ unit_id → decode C0/C1/AA   │
│ （纯函数，零硬件依赖）        │
└──────────────┬───────────────┘
               │ frame{unit_id, ftype, fields, raw}
               ▼
┌──────────────────────────────┐
│ xye_bridge.lua               │
│ C0_RESP → store.ensure_device│
│         → store.write_point  │
│ C1_RESP → 只作在线依据        │
│ C0_POLL / AA → 忽略          │
│ 45s 超时 → store.write_      │
│   device_offline             │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ system/store.lua             │
│ cache[unit_id][tag] = {      │
│   value, errcode, ts         │
│ }                            │
│ tag 用字符串：               │
│ "op_mode" "t1_temp" ...      │
└──────────────┬───────────────┘
               │ get_point_values()
               ▼
┌──────────────────────────────┐
│ wireless/mqtt/protocol/      │
│ report.lua                   │
│ 整点 real 全量 / 周期 change │
│ 快速上报 realIndex           │
└──────────────┬───────────────┘
               │ sender.publish(topics.UP_DATA, payload, 1)
               ▼
┌──────────────────────────────┐
│ wireless/mqtt/basic.lua      │
│ broker.emqx.io:1883         │
│ CLIENT_ID = YEDtest_EPM_     │
│   mqtt_<UID>                 │
└──────────────────────────────┘
```

### store 内部数据结构

```lua
-- tag 用字符串（"op_mode" / "t1_temp" / "compressor_run" ...）
-- 以后加 Modbus 协议转换时，只需加一层 tag → s_addr 的映射表
-- 缓存层本身完全不动

cache[unit_id][tag] = {
    value   = 数值,       -- 实际温度/模式值等
    errcode = 0,          -- 0=正常, 其他=错误码（离线=0x0B）
    ts      = os.time(),  -- 采集时的 unix 秒时间戳
}
```

### store 对外 API

| API | 说明 |
|---|---|
| `store.init()` | 空初始化 |
| `store.is_ready()` | 缓存层就绪状态 |
| `store.ensure_device(unit_id)` | 新设备登记 |
| `store.write_point(unit_id, tag, value, errcode)` | 写一个点位 |
| `store.write_device_offline(unit_id, errcode)` | 离线：所有点写同一个 errcode |
| `store.read_point(unit_id, tag)` | 读一个点位 |
| `store.get_online_devices()` | 当前有数据的 unit_id 列表 |
| `store.get_point_values()` | 返回所有点位（report 依赖，格式对齐二合一） |
| `store.get_reg_by_tag(dev_id, tag)` | 判断 (dev_id, tag) 是否有效（report.start_index_real 依赖） |
| `store.get_slot_by_tag(dev_id, tag)` | 单板 EPM 返回 nil（监听-only） |
| `store.set_by_tag(dev_id, tag, val)` | 返回 false, ERR_NOT_SUPPORTED（监听-only，口子留着） |

---

## 6. MQTT 协议

### 6.1 连接参数

| 项 | 值 |
|---|---|
| broker | `broker.emqx.io:1883` |
| CLIENT_ID | `YEDtest_EPM_mqtt_<UID>`（UID = `mcu.unique_id():toHex()`） |
| 订阅 | `/s/<UID>` `/s2/<UID>` `/scr/<UID>` |
| 发布上行 | `/d/<UID>` |
| QoS | 0 |

> 部署参数在 `wireless/mqtt/basic.lua` 顶部硬编码，现场修改即可。

### 6.2 上行报文

#### real（整点全量）

对齐 5 分钟整点（由 `config.upload_interval_min` 控制），`report_real_enable=true` 时才发。

```json
{
  "t": "real",
  "ti": "2026-11-27 16:45:00",
  "d": {
    "8": {
      "op_mode":    {"q": "1", "t": "1795769100", "v": "168"},
      "t1_temp":    {"q": "1", "t": "1795769100", "v": "25.00000"},
      "compressor_run": {"q": "1", "t": "1795769100", "v": "1"}
    },
    "9": { ... }
  }
}
```

| 字段 | 含义 |
|---|---|
| `t` | 上报类型：`real` / `change` / `realIndex` |
| `ti` | 总时间戳（整点对齐，`YYYY-MM-DD HH:MM:SS`） |
| `d` | 按设备聚合，key 是 unit_id 的字符串（如 `"8"` = 0x08） |
| `q` | 质量位：`"1"`=正常，`"0"`=采集失败（服务端只存储 q=1 的数据） |
| `t` | 点位时间戳（unix 秒字符串） |
| `v` | 值（字符串形式，温度保留 5 位小数） |

#### change（变化检测）

每 `config.change_check_sec` 秒对比一次快照，有变化就发。`report_change_enable=true` 时才发。只包含有变化的 tag。

#### realIndex（快速上报）

由平台通过 `/scr/<UID>` 下发指令触发，立即上报一次后按指定周期持续上报 N 秒，用于"首页快速刷新"等场景。

### 6.3 时间有效性门控

NTP 校时前 `os.time()` 停在 2000-01-01，上报 task 里硬编码 `TIME_VALID_MIN = 1600000000`（2020-09-13），未校时前所有上报函数直接 return，不会发假时间戳。

### 6.4 下行指令

平台通过订阅的 topic 下发指令，`mqtt/protocol/down.lua` 解析分发：

| topic | type | 作用 |
|---|---|---|
| `/s/<UID>` | `cfg.set` | 写运行时配置参数 |
| `/s/<UID>` | `cfg.get` | 读全部配置 / 指定参数 / 只读状态 |
| `/s/<UID>` | `indexReal` | 触发 realIndex 快速上报 |
| `/s2/<UID>` | `ota` | OTA 固件升级 |

所有写参数都经过 `cfg.lua` 的**白名单 + 类型校验 + 范围校验**，不合法直接回 `fail:["param"]`。

---

## 7. 运行时配置

配置文件位置：`/gateway_cfg.json`，首次启动自动写入默认值。

### 7.1 默认参数

| key | 默认值 | 类型 | 范围 | 说明 |
|---|---|---|---|---|
| `upload_interval_min` | `5` | number | 1~60 | real 整点上报间隔（分钟） |
| `change_check_sec` | `5` | number | 1~60 | change 变化检测周期（秒） |
| `report_real_enable` | `false` | bool | — | real 开关，默认关闭 |
| `report_change_enable` | `false` | bool | — | change 开关，默认关闭 |
| `write_through_en` | `true` | bool | — | MQTT 下发写点位闸门（暂未实现写入能力） |
| `u1_baudrate` | `4800` | number | 1200~115200 | XYE 串口波特率（需重启） |
| `u1_databits` | `8` | number | 5~8 | 数据位（需重启） |
| `u1_stopbits` | `1` | number | 1~2 | 停止位（需重启） |
| `u1_parity` | `"N"` | string | N/E/O | 校验位（需重启） |

### 7.2 远程配置

平台下发 JSON 格式指令（topic: `/s/<UID>`）：

**读参数**
```json
{"t": "cfg", "d": {"get": ["upload_interval_min", "csq", "uptime_s"]}}
```

**写参数**
```json
{"t": "cfg", "d": {"set": {"report_real_enable": true, "change_check_sec": 10}}}
```

**恢复出厂**
```json
{"t": "cfg", "d": {"factory_reset": true}}
```

串口参数（`u1_*`）写成功后会落盘，但需要**手动重启**才生效（`cfg.lua` 会回 `need_reboot: true`）。

---

## 8. OTA 与状态灯

### 8.1 NET 状态灯（GPIO27）

| 状态 | 行为 | 触发事件 |
|---|---|---|
| 开机 / 离线 | **快闪**（100ms 周期：50ms 亮 + 50ms 灭） | 默认 |
| MQTT 已连接 | **常亮** | `MQTT_CONNECTED` |
| MQTT 断开 | **快闪** | `MQTT_DISCONNECTED` |

事件由 `mqtt/basic.lua` 在 connect success / 任何异常断开时 publish。

### 8.2 恢复出厂（GPIO30）

| 条件 | 行为 |
|---|---|
| 按住 ≥ 7000ms | 调 `config.factory_reset()`：删 `/gateway_cfg.json` → 重启 |
| 按住 3000ms | 日志提示"检测到长按，已按住 XXXXms" |
| 松开（未达 7000ms） | 日志提示取消 |

### 8.3 OTA

`wireless/ota.lua` require 即自动注册：平台通过 `/s2/<UID>` 下发 OTA 指令 → 下载固件 → 校验 → 升级 → 重启。具体参数见二合一工程 `wireless/ota.lua`。

---

## 9. XYE 协议要点

### 9.1 帧格式

所有帧以 `0xAA` 开头，以 `0x55` 结尾，CRC 位于**倒数第二字节**：

```
[len-2] = CRC,  [len-1] = 0x55
```

| 帧类型 | 长度 | 形态 |
|---|---|---|
| C0 轮询 | 16 B | `AA C0 <...> <crc> 55` |
| C0 应答 | **32 B** | `AA C0 80 00 <unit_id> 00 E0 14 <fields> <crc> 55` |
| C1 轮询 | 16 B | `AA C1 <unit_id> 00 80 <...> <crc> 55` |
| C1 应答 | **32 B** | `AA C1 80 00 <unit_id> 00 <status 24B> <crc> 55` |
| AA 短帧 | 10 B | `AA <cmd> <payload 6B> <crc> 55` |

> 早期文档写"C1 应答 30 字节"，实测为 **32 字节**，按 32 字节校验全部通过，判定为文档笔误。

### 9.2 校验算法

设帧为 `AA ... <CRC> <55>`：

```
sum(AA ... CRC) & 0xFF == 0xAA
```

注意：**校验范围止于 CRC，不含末尾 0x55**。含进去会导致全部帧校验失败。

### 9.3 轮询节奏

每一轮由 CCM 主站发起，共 **109 帧**：

| 组成 | 帧数 | 说明 |
|---|---|---|
| C0 轮询 | 64 | 对 0x00~0x3F 全部 unit_id 点名 |
| C0 应答 | 11 | 只有在线的室内机应答 |
| C1 轮询 | 11 | 只对在线设备发 |
| C1 应答 | 11 | 对应 C1 轮询 |
| AA 短帧 | 12 | 11 台设备各 1 帧 + 1 帧 `AA 00` 全局帧 |
| **合计** | **109** | 周期约 **13.45 s**，轮间静默约 1.82 s |

**重要**：判断设备是否在线，**只能依据 C0_RESP / C1_RESP 应答帧**，不能依据轮询帧里的 unit_id。

### 9.4 在线设备清单（现场实测）

```
0x08 0x09 0x0A 0x0B 0x0C 0x0D 0x0E 0x0F
0x28 0x29 0x2A
```

---

## 10. C0 应答字段解码

32 字节布局（以 unit 0x08 实帧为例）：

```
AA C0 80 00 08 00 E0 14 A8 04 19 58 3A 3A FF FF
00 00 00 01 00 14 00 00 00 00 00 14 FF FF 0E 55

字节:  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
       AA C0 80 00 08 00 E0 14 A8 04 19 58 3A 3A FF FF
                          ↑  ↑  ↑  ↑  ↑  ↑  ↑  ↑  ↑
                        b7 b8 b9 b10 b11 T1 T2 T2B T3
```

### 10.1 字段表

| 字节 | codec 键名 | 含义 | 置信度 | 备注 |
|---|---|---|---|---|
| 7 | `unknown_1` | 未知 | — | 全设备恒为 `0xE0` |
| 8 | `caps` | 能力标志 | 高 | 全部为 `0x14`（0x10 摆风 + 0x04） |
| 9 | `op_mode` | 运行模式 | 中高 | `0x00`关 / `0x80`自动 / `0x88`制冷 / `0xA8`=0x88+bit5 |
| 10 | `fan_mode` | 风扇模式 | 高 | bit7=自动风，低 4 位=档位（`0x04`=低风） |
| 11 | `target_temp_raw` | 设定温度原始值 | 中 | 智谷设备疑似直接 °C（21~25℃） |
| 12 | `t1_temp` | 室内回风温度 | **高** | `(x - 0x28) / 2` |
| 13 | `t2_temp` | 盘管温度 | **高** | 同上；制冷时 8~12℃ |
| 14 | `t2b_temp` | 盘管排温度 | 高 | 同上 |
| 15 | `t3_temp` | 室外温度 | 高 | 恒为 `0xFF` → nil（内机不测） |
| 16 | `current` | 电流 | 高 | 恒为 `0xFF`（内机不测） |
| 18 | `timer_start` | 定时启动 | 高 | bitmask，0=未设置 |
| 19 | `timer_stop` | 定时关机 | 高 | bitmask，0=未设置 |
| 20 | `compressor_run` | 压缩机运行 | 中 | `0x01`=运行；系统级共享状态 |
| 21 | `mode_flags` | 模式标志 | 高 | bit0=ECO，bit1=AUX，bit2=摆风 |
| 22 | `op_flags` | 运行标志 | 高 | bit2=水泵，bit7=水锁 |
| 23-24 | `err_flags_low/high` | 故障标志 16bit | 高 | 0=无故障 |
| 25-26 | `prot_flags_low/high` | 保护状态 16bit | 高 | bit1=除霜 |
| 27 | `ccm_err` | CCM 通信错误 | 高 | 0=正常 / 1=超时 / 2=CRC错 / 4=协议错 |
| 28 | `byte28` | 设备固有码 | 高 | 每台固定，与 C1 byte28 一致 |
| 29-30 | `byte29/30` | 未知 | — | 恒为 `FF FF` |

### 10.2 温度公式

```
温度(℃) = (raw - 0x28) / 2.0
raw = 0xFF → 表示无数据（nil）
```

验证：unit 0x08 的 T2 在 `0x38~0x40` 波动 → 8~12℃，符合制冷盘管温度。

### 10.3 store 中对应的 tag

`xye_bridge.lua` 把 codec 字段名做了少量清洗后写入 store：

| codec 字段 | → store tag | 说明 |
|---|---|---|
| `target_temp_raw` | `set_temp`（数值）+ `target_temp_raw`（原值） | byte11 清 bit6 得到实际温度；`0xFF` → nil |
| `op_flags` bit2 | `op_waterpump` | 布尔 → 0/1 |
| `mode_flags` bit0/1/2 | `mode_eco` / `mode_aux` / `mode_swing` | 布尔 → 0/1 |
| `compressor_run == 1` | `compressor_run` | 1/0 |
| `err_flags_high * 256 + err_flags_low` | `fault_code` | 高低字拼成 16bit |
| `prot_flags_high * 256 + prot_flags_low` | `protect_code` | 高低字拼成 16bit |
| 其他 | 同名 | 原值写入 |

---

## 11. C1 / AA 帧说明

### 11.1 C1 应答

**结构已知，语义未完全确认。** bridge 里只把 C1_RESP 作为"设备在线"的依据，**不写字段到 store**。

已确认规律：
- byte7（值 A）**= 对应设备 AA 短帧 payload[2]**（已验证 11/11）
- byte28 = 设备固有码（与 C0 byte28 完全一致）
- 值 A / 值 B 非零 ⟺ 室内机处于开机状态（11/11 成立）

### 11.2 AA 短帧

**结构已知，bridge 完全忽略（不登记设备也不写字段）。**

规则：`AA <cmd> <payload[1..6]> <crc> 55`，**`cmd = unit_id + 1`**。

| AA cmd | 对应 unit_id |
|---|---|
| 0x09 ~ 0x10 | 0x08 ~ 0x0F |
| 0x29 ~ 0x2B | 0x28 ~ 0x2A |
| 0x00 | 全局帧（无 unit_id） |

payload[1] 是有效标志：`0x02`=有数据 / `0x00`=空闲。

---

## 12. 离线判定

**45 秒**无应答判离线。实现位置：`xye_protocol/xye_bridge.lua` 里的 `offline_task()`。

| 条件 | 动作 |
|---|---|
| 收到 C0_RESP 或 C1_RESP | `seen_ms[unit_id] = mcu.ticks()`（刷新在线时间） |
| 连续 45s 未收到任何应答 | 从 `seen_ms` 移除 → `store.write_device_offline(unit_id, 0x0B)` |

离线后 store 中该设备的**所有点位 errcode 被置 0x0B**（Modbus "目标设备无响应"，与二合一 store 保持一致），上报时质量位 `q="0"`，服务端不存储。

---

## 13. 为后续扩展预留

### 13.1 加 Modbus 协议转换

当前工程**故意不做** tag → s_addr 映射。以后加时：

1. 新建 `modbus_profile.lua`：`{ op_mode = 0x0000, t1_temp = 0x0001, ... }`
2. 新建 `modbus_slave.lua`：收到上位机读寄存器请求 → 查 store → 按映射表返回值
3. **store.lua 和 xye_bridge.lua 完全不动**

### 13.2 加 XYE 写入 / 控制

当前 bridge 只处理 C0_RESP / C1_RESP，listener 的方向脚固定低。以后加时：

1. codec 里补 C3 SET 帧的组帧函数（16 字节，byte13 补码 + byte14 CRC）
2. listener 增加方向脚切换（GPIO25 高电平发送，发完拉低）
3. bridge 在每轮约 1.82s 的静默窗口发送，避免与 CCM 主站撞车
4. store.set_by_tag() 里实现"写 tag → 组 C3 帧 → 发送"逻辑

### 13.3 加板型切换

当前所有引脚硬编码，config.lua 无 `point_table_id`。以后加多板型时：

1. 新建 `board.lua` 按 `rtos.bsp()` 返回 profile
2. 所有硬编码引脚改从 board.profile 取
3. config.lua 加 `point_table_id` 并按板型过滤参数白名单

---

## 14. 已知坑

| # | 坑 | 解决 |
|---|---|---|
| 1 | 校验含 0x55 导致全部帧校验失败 | 校验范围止于 CRC，不含末尾 0x55 |
| 2 | C1 应答被误判为 30 字节 | 实际 32 字节，按 32 字节校验 |
| 3 | C0_POLL 里的 unit_id ≠ 设备在线 | 只认 C0_RESP / C1_RESP 应答帧 |
| 4 | AA short frame payload[1] 不是固定头 | 它是有效标志 `0x02`/`0x00` |
| 5 | AA payload[2] 才是 C1 byte7 的镜像 | 容易差一位（曾误标为 payload[1]） |
| 6 | `string.format` 占位符与参数数量必须一致 | 曾因占位符 4 个参数 2 个导致 Lua VM 崩溃重启 |
| 7 | 压缩机运行是系统级共享状态 | 11 台全部为 1，不要按内机独立点位理解 |
| 8 | 设定温度不能用 `(raw-0x28)/2` | 智谷设备疑似直接 °C，套偏移公式会出负数 |
| 9 | `report_real_enable` / `change_enable` 默认是 false | 需要平台下发开启，否则整点不会上报 |
| 10 | NTP 校时前 os.time() 停在 2000 年 | report.lua 里 `TIME_VALID_MIN=1600000000` 门控拦住假时间戳 |
| 11 | 时钟跳变（NTP 校时瞬间跨 20+ 年） | report.lua 检测到 `cur_boundary < last_real_ts` 时重置基准，跳过假整点上报 |
| 12 | config 文件存在时新增 key 不会自动追加 | `config.lua` 的 `get()` 做了 fallback 默认值，但落盘的文件里旧 key 还是缺；要么手动删 `/gateway_cfg.json` 让它重写，要么加迁移逻辑 |

---

## 15. 参考资料

| 文件 | 用途 |
|---|---|
| `_extra/Air780_EPM_EHV/*` | 二合一参考工程（MQTT 协议、上报逻辑、OTA、设备支撑模块） |
| `_extra/.../02_协议参考/HomeOps/PROTOCOL.md` | 美的系 XYE 协议文档（命令表、C0 字段、CRC） |
| `_extra/.../02_协议参考/智谷美的XYE现场参考.md` | 现场差异说明 |
| `_extra/.../01_抓包/*.txt` | 原始抓包（约 10256 帧，仅 C0/C1/AA） |

> `_extra/` 已在 `.gitignore` 中忽略，不纳入版本管理。
