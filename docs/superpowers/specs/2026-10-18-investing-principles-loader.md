# 投资理念加载器（Investing Principles Loader）

日期：2026-10-18　状态：**已完成**

> 实现：`assistant/principles.yaml`（原则库）+ `assistant/principles.py`（加载器）
> + 注入到 `advisor.py` 与 `chat.py` 的 prompt。测试见 `tests/test_assistant_principles.py`。

> 免责声明：原则库引用的投资理念来自历史文献与知识笔记，仅供研究参考，不构成投资建议。
> AI 生成内容已与史料核对（见原则文件注释）。所有交易决策由用户自行判断。

## 1. 背景与目标

用户希望理财助手的 advisor 实际应用一套投资理念，起点是白圭（战国初期"治生之祖"）的原则。
要求可维护、易扩展（后续添加段永平等大师）、与现有数值纪律（`policy.py`）共存。

现状：
- `advisor.py` 建议只受数值约束（仓位上限、现金缓冲、风险预算）；
- `chat.py` 回答无理念框架；
- 无文本化的投资原则供 LLM 参考。

## 2. 方案

### 2.1 架构

```
assistant/principles.yaml       ← 原则库（YAML，多大师，易编辑）
assistant/principles.py         ← 加载器（load_principles，返回文本）
    ↓
advisor.py / chat.py            ← 注入 prompt（调用 load_principles_for_prompt()）
    ↓
LLM                             ← 应用原则作为检验框架
```

### 2.2 原则文件结构（`principles.yaml`）

```yaml
masters:
  - name: 白圭
    era: 战国初期
    title: 治生之祖
    source: 《史记·货殖列传》，经 AI 视频引入，已核对原文
    notes: |
      视频为 AI 生成，部分改编已标注。
      白圭的商品周期不适用股市，仅作情绪自检。
    principles:
      - key: 人弃我取
        text: 当市场恐慌、他人抛售时，检查标的是真便宜还是价值陷阱。
        application: 大跌时继续定投指数，按再平衡规则加仓...
      - key: 人取我与
        text: 当市场狂热、他人追涨时，考虑获利了结...
        application: 只通过再平衡卖出超配部分...
      # ... 其他原则
    guardrails: |
      用户的硬性规则始终优先：70%+ 被动指数，<30% 个股，
      不碰期权/杠杆，不做波段。
```

字段说明：
- `name`, `title`, `source`, `notes`：元数据，完整模式展示；
- `principles`：原则列表，每条含 `key`（标题）、`text`（理念）、`application`（实操）；
- `guardrails`：硬性边界，覆盖所有原则（用户的不可逾越规则）。

### 2.3 加载器 API

```python
from assistant.principles import load_principles_for_prompt

# 返回简明文本（token 友好），供 prompt 注入
text = load_principles_for_prompt()
# → "# 白圭\n- 人弃我取：...\n- 人取我与：...\n⚠️ 边界：..."
```

容错：
- 文件缺失或解析失败 → 返回空字符串（不中断流程）；
- prompt 正常生成，只是缺少理念部分。

### 2.4 Prompt 注入

#### advisor.py
```python
principles_text = load_principles_for_prompt()
reply = llm.invoke(_PROMPT.format(
    ticker=ticker, decision=decision, total=total, cash=cash_eur,
    holding_desc=holding_desc, weight=round(weight, 1), price=price,
    constraints=_constraints_text(snap, ticker),
    principles=principles_text,  # ← 新增
)).content
```

prompt 模板添加：
```
仓位纪律（你的建议必须落在这些约束内，否则会被系统钳制）:
{constraints}

{principles}

请给出一条具体操作建议...
```

#### chat.py
```python
principles_text = load_principles_for_prompt()
reply = llm.invoke(_PROMPT.format(
    context=context,
    bilingual=BILINGUAL_INSTRUCTION,
    principles=principles_text,  # ← 新增
    question=chat["question"]
)).content
```

prompt 模板添加：
```
# 投资理念
{principles}

# 组合快照
{context}
```

## 3. 白圭原则内容（第一版）

七个核心原则：

1. **人弃我取**：市场恐慌时检查真便宜还是价值陷阱（独立判断，不机械逆向）。
2. **人取我与**：市场狂热时获利了结，不抓绝对顶部（再平衡机制卖出）。
3. **乐观时变**：观察周期作为背景认知，不据此做行业轮动或波段择时。
4. **留三成、不能先倒**：现金缓冲，判断对了也要活到兑现（现金 ≥5%，个股 ≤30%）。
5. **看对只算一半，等得到才算赢**：耐心持有到价值兑现，不因短期波动频繁进出。
6. **智勇仁强**：
   - 智：看懂变化（估值、基本面）
   - 勇：看懂后敢执行
   - 仁：取予有度，不赚最后一个铜板（达目标即按计划卖）
   - 强：守住判断，不被情绪带走
7. **不把别人的情绪当成自己的判断**：价值判断独立于市场情绪（FOMO/恐慌不触发交易）。

硬性边界（`guardrails`）：
- 70%+ 被动指数，<30% 能力圈内个股（软件/云/SaaS/电商/SCM）
- 不碰期权、杠杆、套利
- **不做波段、不做行业轮动**

→ 白圭的"乐观时变"（跨品类切换）只能解读为指数层面的战略再平衡与情绪自检，
绝不可作为频繁切换个股/行业 ETF 的依据。数值纪律（`policy.py`）永远是硬约束。

## 4. 史料准确性说明

原则基于知识笔记（抖音「书三说」AI 生成视频），已与《史记·货殖列传》维基文库原文对照：

- ✅ 准确：人弃我取、人取我与、乐观时变、智勇仁强、岁孰取谷予之丝漆等引文；
- ⚠️ 改编：视频"仁能以取予"原文为"仁**不**能以取予"（门槛而非格言）；"不赚最后一个铜板"是现代道德化演绎；
- ⚠️ 张冠李戴：视频把计然（范蠡的老师）的"贵上极则反贱"安给白圭；
- 🚫 虚构：具体交易细节（一天跌三次、五倍价求购等）全部虚构。

详见 `uploads/baigui-note.md`。

## 5. 与现有组件的关系

| 组件 | 现状 | 关系 |
|------|------|------|
| `policy.py` | 数值约束（上限、现金、风险预算） | 硬约束，优先级最高；principles 是软指导 |
| `advisor.py` | LLM 自由给建议 → policy 钳制 | prompt 注入 principles，LLM 参考后给建议 |
| `chat.py` | 无理念框架，只有组合快照 | prompt 注入 principles，回答带理念视角 |
| Firestore `meta/policy` | 数值参数配置 | 与 principles 无关（纯函数，无 Firestore 读写） |

**优先级**：用户硬性规则（guardrails） > policy 数值闸门 > LLM 建议（受 principles 影响）。

## 6. 如何添加新大师

1. 编辑 `assistant/principles.yaml`，在 `masters` 列表添加新条目：
   ```yaml
   - name: 段永平
     title: 大道无形投资家
     source: 公开访谈与雪球发言
     principles:
       - key: 本分
         text: 只做能力圈内的事，不懂不做。
         application: 个股仅限软件/云/SaaS/电商/SCM，ETF 只买宽基。
       - key: 敢为天下后
         text: 不抢风口，等确定性。
         application: 不追热点概念股，等财报验证增长假设。
   ```
2. 原则每条写为可操作的检验点（中文表述，简洁明确）。
3. 如有史料准确性说明或应用边界，写在 `notes` 字段。
4. 运行测试确认加载正常：`pytest tests/test_assistant_principles.py -v`。

## 7. 测试

`tests/test_assistant_principles.py`：
- ✅ 加载正常（concise 与 full 模式）
- ✅ 缺失/损坏文件降级不崩溃
- ✅ 白圭七个原则全部出现
- ✅ guardrails 出现

`tests/test_assistant_advisor.py`：
- ✅ prompt 包含 principles（或为空但不抛异常）

`tests/test_assistant_chat.py`：
- ✅ prompt 包含 principles（或为空但不抛异常）

运行：
```bash
pytest tests/test_assistant_principles.py -v
pytest tests/test_assistant_advisor.py::test_prompt_includes_principles -v
pytest tests/test_assistant_chat.py::test_chat_prompt_includes_principles -v
```

## 8. 落地清单

- ✅ `assistant/principles.yaml`：白圭七条原则 + guardrails + 史料说明
- ✅ `assistant/principles.py`：load_principles() + load_principles_for_prompt()
- ✅ `advisor.py`：import + 注入 prompt
- ✅ `chat.py`：import + 注入 prompt
- ✅ `tests/test_assistant_principles.py`：9 个测试全过
- ✅ `tests/test_assistant_advisor.py`：新增 test_prompt_includes_principles
- ✅ `tests/test_assistant_chat.py`：新增 test_chat_prompt_includes_principles
- ✅ 所有 assistant 测试通过（263 个）
- ✅ 本文档（spec）

## 9. 未来扩展

- 添加段永平、查理·芒格等大师（按§6 流程）；
- 多大师联合（concise 模式全部加载，full 模式可选）；
- 用户可配置启用哪些大师（`meta/principles_config`）；
- App 端理念卡片（展示当前加载的理念，可点击展开完整说明）。

## 10. 参考

- 知识笔记：`uploads/baigui-note.md`（含史料核对与用户投资框架对照）
- 用户投资框架：`docs/superpowers/specs/2026-08-02-position-management-policy.md`（§2、§3）
- 《史记·货殖列传》：[维基文库](https://zh.wikisource.org/zh-hans/史記/卷129)
