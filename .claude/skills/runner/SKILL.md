---
name: runner
description: 启动/停止/查看理财助手的 assistant runner（消费 Firestore 任务队列的后台进程）。当用户说「启动 runner」「跑一下 runner」「消费一下队列」「runner 状态」「看 runner 日志」「停掉/重启 runner」，或在 App 里点了分析/刷新/提问后说「没反应」「一直排队中」「怎么还没结果」时，都用本技能。子命令：/runner（常驻 watch 模式）、/runner once（跑一轮退出）、/runner stop、/runner status、/runner log。
---

# Assistant Runner 启停

runner 是理财助手的唯一后台执行器：App 里所有按钮（分析、刷新行情、提问）都只是往
Firestore `jobs` 集合排队，**必须有一个 runner 进程在跑才会真正执行**。用户没装
launchd（刻意决定，手动触发），所以由本技能代管进程。

每轮 wake-up 依次做：僵尸任务清理 → 消费用户排队的 jobs（deep_analysis / daily_brief /
refresh_quotes / chat）→ 按 watchlist 规划定时任务（交易日日报、每周深度分析）→ 行情补齐
→ 财报/分红日历刷新 → 复盘到期建议 → 写心跳（App 首页的「Runner 在线」灯）。

## 固定约定

- 一律在主仓根目录跑（.venv 和 Firebase 凭据都在那，worktree 里没有 .venv）：
  `ROOT=/Volumes/external/code/ai/projects/TradingAgents`
- pid 文件：`/tmp/tradingagents-runner-watch.pid`
- 日志：`/tmp/tradingagents-runner-watch.log`
- watch 默认间隔 120 秒；用户说「每 N 秒」就传 `--watch N`

## /runner —— 常驻 watch 模式（默认动作）

先查有没有活着的实例，避免双消费者。**以 pgrep 实际进程为准**（别只信 pid 文件：
上个会话或用户手动起的 runner 不会写 pid 文件，漏检就会双消费）：

```bash
ROOT=/Volumes/external/code/ai/projects/TradingAgents
PID_FILE=/tmp/tradingagents-runner-watch.pid
EXISTING=$(pgrep -f '^[^ ]*python[^ ]* -m assistant.runner' | head -1)
if [ -n "$EXISTING" ]; then
  echo "$EXISTING" > "$PID_FILE"   # 接管无主实例，之后 stop/status 都认它
  echo "already running pid=$EXISTING (已接管到 pid 文件)"
else
  cd "$ROOT" && nohup .venv/bin/python -m assistant.runner --watch 120 \
    > /tmp/tradingagents-runner-watch.log 2>&1 & echo $! > "$PID_FILE"
  echo "started pid=$(cat $PID_FILE)"
fi
```

启动后 sleep 几秒再 tail 日志确认第一轮 wake-up 正常（watch 模式启动时会自动回收
遗留的 running 孤儿任务，日志里出现 `requeued N orphaned running job(s)` 属正常）。
向用户报告：pid、间隔、以及日志里这轮消费了什么。

## /runner once —— 跑一轮就退出

适合「就消费一下现在排队的任务」：

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && .venv/bin/python -m assistant.runner
```

前台跑完即退（深度分析一单要几分钟，属正常，别中途 kill）。结束后总结日志给用户。

## /runner stop

```bash
PIDS=$(pgrep -f '^[^ ]*python[^ ]* -m assistant.runner')
if [ -z "$PIDS" ]; then rm -f /tmp/tradingagents-runner-watch.pid; echo "not running";
elif [ "$(echo "$PIDS" | wc -l)" -eq 1 ]; then
  kill $PIDS && rm -f /tmp/tradingagents-runner-watch.pid && echo "stopped pid=$PIDS"
else
  echo "multiple instances:"; pgrep -fl '^[^ ]*python[^ ]* -m assistant.runner'
fi
```

恰好一个实例就直接停（pgrep 模式已保证是 runner，不会误杀）；出现多个实例说明状态
异常，列出来让用户决定杀哪个，不要顺手全杀。

## /runner status

1. 进程：`pgrep -fl '^[^ ]*python[^ ]* -m assistant.runner'` + `ps -o pid,etime -p <pid>`
2. 最近活动：`tail -20 /tmp/tradingagents-runner-watch.log`，找最后一条
   `wake-up complete` 和报错；日志文件不存在说明实例是外部启动的（launchd 或上个
   会话），改看 Firestore 心跳 `meta/runner`（lastSeenAt 应在 1 分钟内）
3. 队列积压（可选，用户想知道有没有任务卡着时）：用 python + FirestoreStore 查
   `jobs` 里 status 为 queued/running 的条数

报告格式：在线/离线 + 跑了多久 + 上轮 wake-up 时间 + 队列里还有几单。App 首页的
Runner 心跳灯也依赖它，离线时提醒用户首页会显示离线。

## /runner log

`tail -50 /tmp/tradingagents-runner-watch.log`，把关键行（消费了什么 job、报错栈的
第一行）翻译成人话给用户，不要整段贴原始日志。

## 排错与注意

- 启动前若 `~/.tradingagents/firebase-service-account.json` 或 `$ROOT/.venv` 缺失，
  直接指去 `assistant/README.md` 的部署步骤，不要带病启动。
- 深度分析一单是完整多 agent run，成本数美元量级；runner 只执行用户/定时器排进队列的
  任务，启动 runner 本身不新增任务。
- 改过 assistant/ 代码后要 `/runner stop` 再 `/runner`，常驻进程不会热加载。
- launchd 方案（每 15 分钟自动拉起）见 `assistant/README.md` 第 7 步；用户以后想自动化
  再装，装了就别再用本技能的 watch 模式（避免双消费者）。
