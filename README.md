# VPS Traffic Monitor

Linux VPS 流量监控（纯 Bash 数字菜单）。
阈值触发后先确认所有已启用通知均已送达，再执行 **停 address**、**关机**等动作。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daimon3332/vps-traffic-montior/main/vps-traffic-monitor.sh)
```

安装后终端输入 **`m` 回车** 打开菜单（与 [kejilion](https://github.com/kejilion/sh) 的 `k` 一样，装到 `/usr/local/bin/m`，不依赖 alias）。

也可：`vtm`

## 主菜单

启动即显示本月上行 / 下行 / 合计、通知与规则。

| 数字 | 作用 |
|------|------|
| 1 | **添加规则**（名称 → 上行/下行/合计 → 阈值 → 是否停 address / 关机） |
| 2 | 删除规则 |
| 3 | 通知设置（Telegram / 邮件，测试成功才保存） |
| 4 | **后台监控**开关（开启后自动定时检查，不必一直开菜单） |
| 5 | 改快捷键（默认 `m`，写入 `/usr/local/bin`） |
| 6 | 更新脚本 |
| 7 | 校准本周期已用流量（补录安装前流量） |
| 0 | 退出 |

### 这几项分别干什么？

| 你要做的事 | 用哪个 |
|------------|--------|
| 规定「用到多少流量就通知 / 停服 / 关机」 | **1 添加规则** |
| 配机器人、邮箱，让通知能发出去 | **3 通知设置** |
| 让机器自己在后台盯着，不用人一直开着脚本 | **4 后台监控** |
| 让统计包含安装脚本前已经使用的流量 | **7 校准本周期已用流量** |

默认按自然月统计。脚本读取 Linux 网卡计数器，只能自动累计首次运行后的流量；安装前的本周期用量需按云平台控制台数值校准一次。校准值在下个周期自动清零。

### 添加规则示例（Oracle 出站）

1. 名称 `stop-app` → 上行 → `6.5T` → 停 address=Y，关机=N  
2. 名称 `poweroff` → 上行 → `8T` → 停 address=N，关机=Y  
3. 菜单 3 配好通知
4. 菜单 7 校准甲骨文控制台当前出站用量
5. 菜单 4 开启后台监控

## 命令行

```text
m                        # 装好后的快捷键（可改）
bash 脚本路径            # 打开菜单
--check                  # 静默检查（给后台 timer）
--status
--test-telegram / --test-email / --test-notify
--install / --update
--install-timer / --uninstall-timer
--set-used up 4.2T      # 校准本周期上行已用流量
```

`K/M/G/T`、`KB/MB/GB/TB` 和 `KiB/MiB/GiB/TiB` 均按 1024 进制解析，状态显示使用 IEC 单位。

## 路径

- 配置：`/root/vps-traffic-monitor/config.conf`
- 状态：`/var/lib/vps-traffic-monitor/state`
- 日志：`/var/log/vps-traffic-monitor.log`
- 停 address：`/root/address/app/ops/stop.sh`

## 安全

配置与状态文件会收紧为仅 root 可读写。停服 / 关机规则在通知失败时不会继续执行，并会在下一次后台检查时重试。
