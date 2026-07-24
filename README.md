# VPS Traffic Monitor

通用 Linux VPS 流量监控（纯 Bash + 数字 TUI）。监控上行 / 下行 / 总流量，按阈值执行通知、自定义命令（如停服务）、关机。多机各用一份配置即可。

风格与交互参考 [linux-tools-daimon](https://github.com/daimon3332/linux-tools-daimon)。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daimon3332/vps-traffic-montior/master/vps-traffic-monitor.sh)
```

> 将 URL 换成你自己的仓库 raw 地址。国内若 GitHub 不稳定，可先下载到本地再 `bash vps-traffic-monitor.sh`。

## 本地运行

```bash
chmod +x vps-traffic-monitor.sh
./vps-traffic-monitor.sh
```

打开后**默认显示总览**：当前流量、已配置服务（通知 / 规则 / 命令 / 定时任务）、规则触发状态，再通过数字进入子菜单。

## 命令行

| 参数 | 说明 |
|------|------|
| （无） / `--menu` | TUI 菜单 |
| `--check` | 静默检查并执行规则（给 systemd timer） |
| `--status` | 打印流量状态 |
| `--test-notify` | 测试 Telegram / 邮件 |
| `--install` | 安装到 `/root/vps-traffic-monitor/` |
| `--install-timer` | 安装 systemd 定时任务 |
| `--uninstall-timer` | 卸载定时任务 |

## 典型场景（Oracle 出站 10T）

1. 启动菜单 → `[9] 高级` → 应用 Oracle 示例规则  
   或复制 `configs/example-oracle.conf` 为 `config.conf`
2. `[3] 通知设置` 配置 Telegram 和/或邮件（至少一种）
3. 确认命令 `stop_heavy_app` 指向你的停服脚本（示例为 address 的 `ops/stop.sh`）
4. 建议先 `[9]` 打开 **dry-run**，`[2]` 立即检查，确认逻辑
5. 关闭 dry-run → `[8]` 安装定时任务

效果：

- 出站达到 **6.5T** → 通知 + 停止重业务服务  
- 出站达到 **8T** → 通知 + 延迟关机  
- 配额展示 **10T**（可改）

## 配置说明

路径默认：`/root/vps-traffic-monitor/config.conf`

| 项 | 说明 |
|----|------|
| `INSTANCE_NAME` | 通知里显示的实例名 |
| `INTERFACE` | 网卡，空=自动选默认路由网卡 |
| `METRIC` | `up` / `down` / `sum` / `max` / `min` |
| `RESET_DAY` | 每月重置日（1–28） |
| `QUOTA` | 配额展示，如 `10T` |
| `RULE_n` | `名称\|阈值\|计量\|动作` |
| `CMD_名称` | 命名命令，规则里 `run:名称` |
| `TG_*` / `MAIL_*` | 通知 |
| `DRY_RUN` | `1` 只模拟不执行 |

规则动作：

- `notify` — Telegram + 邮件（按开关）
- `run:foo` — 执行 `CMD_foo`
- `shutdown` — 延迟后关机

同一计费周期内每条规则只触发一次。

## 多机部署

每台 VPS：

1. 安装脚本  
2. 各自编辑 `config.conf`（阈值、命令、通知可不同）  
3. 安装 timer  

代码通用，**不绑定**某台机器或 address；停服路径只写在配置里。

## 目录

```text
vps-traffic-monitor.sh    # 主程序
config.example.conf       # 模板
configs/example-oracle.conf
systemd/                  # unit 示例（菜单安装时也会自动写入）
```

运行时数据：

- 配置：`/root/vps-traffic-monitor/config.conf`
- 状态：`/var/lib/vps-traffic-monitor/state`
- 日志：`/var/log/vps-traffic-monitor.log`

## 依赖

- bash 4+、curl、iproute2、systemd（定时任务可选）
- 邮件：curl SMTP（推荐）或 sendmail

## 安全提示

- 关机与停服为破坏性操作，生产环境请先 dry-run
- 勿将含 token/密码的 `config.conf` 提交到 Git
