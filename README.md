# VPS Traffic Monitor

通用 Linux VPS 流量监控（纯 Bash + 数字菜单）。  
到阈值时**一定发通知**；可选再**停 address**、**关机**（可都不选 / 只选一个 / 两个都选）。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daimon3332/vps-traffic-montior/main/vps-traffic-monitor.sh)
```

## 主菜单（尽量简单）

启动后先看本月上行 / 下行 / 合计、通知与规则状态。

| 数字 | 做什么 |
|------|--------|
| 1 | 刷新 |
| 2 | 立即检查一次 |
| 3 | **添加规则**（向导） |
| 4 | 删除规则 |
| 5 | 通知设置 / 测试 |
| 6 | 开启或关闭定时检查 |
| 7 | 简单设置（配额、重置日、模拟模式等） |
| 8 | 更新脚本 |
| 0 | 退出 |

### 添加规则向导（菜单 3）

1. 输入**规则名称**  
2. 选流量方向：**上行 / 下行 / 双向合计**  
3. 输入阈值，如 `6.5T`  
4. 问是否**停 address**、是否**关机**（都可答 N，只通知）  
5. 确认后保存  

触发时**始终通知**；额外动作按你的选择执行。

### 通知（菜单 5）

- 配置 Telegram / 邮件时会**先发测试，成功才保存**  
- 也可单独测试 Telegram / 邮件  

## 典型：Oracle 出站 10T

1. 菜单 5 配好 Telegram 或邮件  
2. 菜单 3 加两条规则：  
   - 名称 `stop-app`，上行，`6.5T`，停 address=Y，关机=N  
   - 名称 `poweroff`，上行，`8T`，停 address=N，关机=Y  
3. 菜单 7 可把「模拟模式」先设为 `1` 试跑，确认后改 `0`  
4. 菜单 6 开启定时检查  

## 命令行

```text
--check            静默检查（给 timer）
--status           看流量
--test-telegram    测 Telegram
--test-email       测邮件
--test-notify      测已开启通道
--install          安装到 /root/vps-traffic-monitor/
--update           更新脚本
--install-timer    开定时
--uninstall-timer  关定时
```

## 配置路径

- 配置：`/root/vps-traffic-monitor/config.conf`  
- 状态：`/var/lib/vps-traffic-monitor/state`  
- 日志：`/var/log/vps-traffic-monitor.log`  
- address 停止脚本默认：`/root/address/app/ops/stop.sh`（菜单 7 可改）

## 安全

- 停服 / 关机有破坏性，建议先开模拟模式（dry-run=1）  
- 不要把含 token 的 `config.conf` 提交到 Git  
