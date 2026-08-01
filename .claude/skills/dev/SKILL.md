---
name: dev
description: 一键本地启动/停止理财助手全套环境（Flutter Web 助手 + assistant runner）。当用户说「启动助手」「本地启动」「把 app 跑起来」「一键启动」「打开理财助手」「本地环境起一下」「都停掉」「重启 web」「热重载一下」时用本技能。子命令：/dev（web + runner 全部启动）、/dev stop（全部停止）、/dev status（两者状态汇总）、/dev web（只启/重启 web）、/dev reload（热重启 web，改完 Dart 代码后用）。
---

# 本地开发环境一键启停（助手 + runner）

理财助手完整跑起来需要两个进程，缺一不可：

| 进程 | 作用 | 死了的症状 |
|------|------|-----------|
| **web 助手** | Flutter Web 界面，http://localhost:8765 | 页面打不开 / 改代码看不到效果 |
| **runner** | 消费 Firestore `jobs` 队列的后台执行器 | 按钮点了「一直排队中」，首页显示 Runner 离线 |

runner 的启停细节**一律以 `/runner` 技能为准**（本技能只负责编排和汇总，不要在这里
复制它的命令——用 Skill 工具调 `runner`，需要停就传 `stop`）。

## 固定约定（web 部分）

- 主仓根目录：`ROOT=/Volumes/external/code/ai/projects/TradingAgents`
- pid 文件：`/tmp/tradingagents-flutter-web.pid`；日志：`/tmp/tradingagents-flutter-web.log`
- 端口固定 8765
- **定位进程一律用 pgrep，pid 文件只是参考**（可能是陈尸或缺失，绝不直接对它的内容发信号）：

```bash
WEB_PID=$(pgrep -f 'flutter_tools.snapshot run -d web-server --web-port 8765' | head -1)
```

- 探活一律带超时（web dev server 编译期间会挂起请求，假死进程会永不回包）：

```bash
curl -s -o /dev/null -w '%{http_code}' --max-time 5 --connect-timeout 2 http://localhost:8765
```

## /dev —— 全部启动（默认动作）

顺序：先 runner 后 web（runner 用 Skill 工具调 `/runner`，它自带防双消费者检查）。

```bash
ROOT=/Volumes/external/code/ai/projects/TradingAgents
PID_FILE=/tmp/tradingagents-flutter-web.pid
LOG=/tmp/tradingagents-flutter-web.log
EXISTING=$(pgrep -f 'flutter_tools.snapshot run -d web-server --web-port 8765' | head -1)
if [ -n "$EXISTING" ]; then
  echo "$EXISTING" > "$PID_FILE"   # 接管无主实例（手动/上个会话启动的也认领）
  echo "web already running pid=$EXISTING"
else
  cd "$ROOT/app" && nohup flutter run -d web-server --web-port 8765 \
    --pid-file "$PID_FILE" > "$LOG" 2>&1 &
  echo "web starting..."
fi
```

**已在运行的分支不要做日志轮询**（日志可能是上次会话的、甚至不存在），直接用固定约定
里的 curl 探活，200 即就绪。

**新启动的分支**轮询日志等编译完成（首次编译约 30–60 秒，别提前宣布成功；第 3 轮起
顺带查进程死活，编译崩了就别空等）：

```bash
for i in $(seq 1 40); do
  grep -q "is being served at" "$LOG" 2>/dev/null && break
  sleep 3
  [ "$i" -ge 3 ] && ! pgrep -f 'flutter_tools.snapshot run -d web-server --web-port 8765' >/dev/null && break
done
grep "is being served at" "$LOG" 2>/dev/null || { echo "--- 未就绪，日志尾部 ---"; tail -20 "$LOG"; }
```

超时但进程还在且日志无报错 → 可能只是编译慢，再 curl 探活一次并适当续等，别急着判死。

就绪后用浏览器面板打开 http://localhost:8765 截图确认页面正常渲染，再向用户报告：
web pid + 地址、runner pid + 间隔、两者日志各自的关键行。用户自己浏览器也可直接开
http://localhost:8765。

## /dev stop —— 全部停止

1. runner：用 Skill 工具调 `runner`，args 传 `stop`
2. web：

```bash
PID=$(pgrep -f 'flutter_tools.snapshot run -d web-server --web-port 8765' | head -1)
if [ -n "$PID" ]; then kill "$PID" && rm -f /tmp/tradingagents-flutter-web.pid && echo "web stopped pid=$PID"
else rm -f /tmp/tradingagents-flutter-web.pid; echo "web not running"; fi
```

kill 的是 flutter tool 进程，它会自己带走 web server 子进程；不要 kill -9。

## /dev status —— 状态汇总

1. web：`pgrep -fl 'flutter_tools.snapshot run -d web-server'` + 固定约定里的 curl 探活。
   判定：200 = 健康；curl 超时（exit 28 / 000）但进程在 = **在但不健康**（可能正在
   编译，稍候重试一次；仍超时就是假死，建议 /dev web 重启）；进程不在 = 未启动
2. runner：用 Skill 工具调 `runner`，args 传 `status`
3. 汇总成一张两行小表报告：进程在不在、跑了多久、web 可否访问、runner 上轮 wake-up 时间

## /dev web —— 只启/重启 web

按 `/dev` 里 web 那段执行；若已有实例且用户意图是「重启」（比如改了 pubspec/资产文件），
先按 `/dev stop` 的 web 段停掉再启。

## /dev reload —— 热重启 web

改完 `app/` 下的 Dart 代码后用。**用 pgrep 定位，不 cat pid 文件**（陈尸 pid 被系统
复用后，对它发 USR2 会误杀无关进程）；发完信号要在日志里等到结果才算数，`kill` 返回
成功只代表信号送达，重编译是异步的：

```bash
LOG=/tmp/tradingagents-flutter-web.log
PID=$(pgrep -f 'flutter_tools.snapshot run -d web-server --web-port 8765' | head -1)
if [ -z "$PID" ]; then echo "web not running，走 /dev web 启动"; else
  BEFORE=$(cat "$LOG" 2>/dev/null | wc -l)
  kill -USR2 "$PID"
  for i in $(seq 1 10); do
    tail -n +"$((BEFORE+1))" "$LOG" 2>/dev/null | grep -qE "Restarted application|Failed to recompile" && break
    sleep 2
  done
  tail -n +"$((BEFORE+1))" "$LOG" 2>/dev/null | grep -E "Restarted application|Failed to recompile|Recompile complete" \
    || echo "no log feedback（老实例没日志文件）：sleep 5 后用页面内容验证改动生效"
fi
```

结果判读：

- `Restarted application in …` = 成功
- `Failed to recompile application.` = 改动有编译错误，页面还在跑**旧代码**，把日志里的
  编译错误贴给用户
- `Recompile complete. No client connected.` = 当时没有浏览器页面连着，只完成了重编译；
  已断连的旧页面不会更新，刷新或新开 http://localhost:8765 才生效
- 毫无反应 = flutter tool 正忙（处理上一个请求时会静默丢弃信号），隔几秒重发一次

注意：热重启会**清空应用内存状态**（路由、表单、登录态），重载后回到首页属正常现象，
不是改坏了。**只对 Dart 代码有效**；新增资产、改 pubspec.yaml、改 web/ 下文件需要完整
重启（/dev web 的重启流程）。

## 排错与注意

- 端口被占（日志出现 `Address already in use`）：`lsof -ti :8765` 找占用者——多半是
  上次没停干净的 web 实例，确认后 kill 再启；不是本项目的进程就换问题报给用户。
- web 起来了但页面空白/一直转圈：看 `/tmp/tradingagents-flutter-web.log` 编译错误，
  浏览器面板 read_console_messages 看运行时错误。
- 改了 `assistant/` Python 代码 → runner 不会热加载，要调 `runner` 技能 stop 再启。
- 改了 `app/` Dart 代码 → `/dev reload` 即可，不用重启。
- 历史遗留：早期会话用过 `/tmp/flutter-web.pid` 旧路径，见到可直接删；由它启动的老
  实例没有日志文件，reload 按「no log feedback」路径验证。
- 本技能与 `/runner` 技能共存：单独操作 runner 时依旧直接用 `/runner`。
