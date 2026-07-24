# VPS Traffic Monitor

Linux VPS 流量监控（纯 Bash 数字菜单）。  
**到阈值一定发通知**；可选再 **停 address**、**关机**。

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
| 0 | 退出 |

### 这几项分别干什么？

| 你要做的事 | 用哪个 |
|------------|--------|
| 规定「用到多少流量就通知 / 停服 / 关机」 | **1 添加规则** |
| 配机器人、邮箱，让通知能发出去 | **3 通知设置** |
| 让机器自己在后台盯着，不用人一直开着脚本 | **4 后台监控** |

没有「配额 / 重置日 / 模拟模式」一堆高级项；每月按自然月统计，默认足够用。

### 添加规则示例（Oracle 出站）

1. 名称 `stop-app` → 上行 → `6.5T` → 停 address=Y，关机=N  
2. 名称 `poweroff` → 上行 → `8T` → 停 address=N，关机=Y  
3. 菜单 3 配好通知  
4. 菜单 4 开启后台监控  

## 命令行

```text
m                        # 装好后的快捷键（可改）
bash 脚本路径            # 打开菜单
--check                  # 静默检查（给后台 timer）
--status
--test-telegram / --test-email / --test-notify
--install / --update
--install-timer / --uninstall-timer
```

## 路径

- 配置：`/root/vps-traffic-monitor/config.conf`
- 状态：`/var/lib/vps-traffic-monitor/state`
- 日志：`/var/log/vps-traffic-monitor.log`
- 停 address：`/root/address/app/ops/stop.sh`

## 安全

停服 / 关机有破坏性；含 token 的配置不要提交 Git。
