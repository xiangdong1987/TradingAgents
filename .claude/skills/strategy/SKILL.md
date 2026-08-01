---
name: strategy
description: 对持仓/自选股跑量化策略（海龟等）生成买卖建议。当用户说「跑一下海龟」「用策略扫一下持仓」「/strategy turtle」「看看有没有突破信号」「策略建议」「扫描持仓」，或想启用/关闭/调参某个策略、查看有哪些策略时使用。子命令：/strategy（列出策略与配置）、/strategy <名字> [positions]（跑一次扫描）、/strategy config（查看/改 meta/strategies 配置）。
---

# 量化策略扫描

策略框架在 `assistant/strategies/`（注册表 + 纯函数策略），扫描零 LLM 成本、几秒出结果。
产出写进 `suggestions` 集合（带 `source: <策略名>`），App 今日 tab 建议卡直接显示
（🐢 海龟 chip），采纳/忽略、14 天后自动复盘盈亏与引擎建议同一条流水线。

固定约定：主仓 `ROOT=/Volumes/external/code/ai/projects/TradingAgents`，
Python 一律 `$ROOT/.venv/bin/python`。

## /strategy —— 列出可用策略

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && .venv/bin/python -c "
from assistant.strategies import REGISTRY
from assistant.store import FirestoreStore
cfg = FirestoreStore.connect().get_strategy_config()
for name, s in REGISTRY.items():
    c = cfg.get(name) or {}
    print(f'{name}({s.label}): enabled={c.get(\"enabled\", False)} '
          f'schedule={c.get(\"schedule\", \"manual\")} params={c.get(\"params\") or s.defaults}')"
```

## /strategy <名字> [scope] —— 手动跑一次

用户点名的策略**无视 enabled 配置**，直接执行。scope 缺省用配置
（缺省 positions+watchlist）；用户说「只扫持仓」传 `positions`。

首选路径：排一条 job 让 runner 消费（与定时扫描同一代码路径）：

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && .venv/bin/python -c "
from assistant.store import FirestoreStore, utc_now_iso
s = FirestoreStore.connect()
jid = s.add_job({'type': 'strategy_scan', 'strategy': 'turtle',
                 'status': 'queued', 'requestedBy': 'user', 'createdAt': utc_now_iso()})
print('queued job', jid)"
```

（要限定持仓就在 dict 里加 `'scope': 'positions'`。）随后每 ~30s 查一次该 job 状态，
done 后把 job 文档里的 `scanned`/`created` 和新建议内容汇报给用户。

runner 没在跑（先用 /runner status 判断）时直跑兜底，效果等同：

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && .venv/bin/python -m assistant.strategies turtle
```

汇报格式：扫描了几只、每条建议一行（ticker / 动作 / 关键数字：突破位、N、股数、止损），
没有信号也要明说「N 只都无信号」——没信号是常态（海龟一年也就几次突破），不是故障。

## /strategy config —— 查看/修改配置

配置在 Firestore `meta/strategies`，形如：

```json
{"turtle": {"enabled": true, "schedule": "manual", "scope": "positions+watchlist",
            "params": {"riskPct": 1.0, "maxUnits": 4,
                       "s1": {"entry": 20, "exit": 10, "filter": true},
                       "s2": {"entry": 55, "exit": 20}}}}
```

- 用户想每天自动扫 → `schedule: "daily"`（收盘后 runner 自动排队）
- 改参数（如 riskPct 0.5）→ 用 python + FirestoreStore 更新 `meta/strategies` 文档
  （`set(..., merge=True)`），改完复述新配置
- 缺省参数在 `assistant/strategies/turtle.py` 的 DEFAULTS，配置只需写差异项

## 注意

- **改过 assistant/ 代码后 runner 要重启**（/runner stop 再 /runner），旧进程不认识新
  job 类型/新逻辑
- 单元账本 = 已采纳的本策略建议序列（+老持仓作种子单元）：用户在券商操作但没在
  App 记录时账本会失真，提醒即可
- 新增策略：写 `assistant/strategies/<name>.py`（末尾 register）+ 在
  `assistant/strategies/__init__.py` 底部加一行 import + 补 tests/，参考 turtle.py
