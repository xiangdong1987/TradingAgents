# 中英双语支持（UI + LLM 内容）设计

日期：2026-08-02　状态：已确认（混合式内容 + 应用内开关 + 引擎报告英文原生、中文按需翻译）

## 决策记录

1. **内容双语 = 混合式**：轻内容（日报/问答/建议理由）生成时一次出双语；
   **深度分析 13 段保持引擎英文原文，不预翻**，用户在中文模式下点「翻译」按钮
   按需排 `translate` job（用户明确修订：trading agent 直接用英文生成报告，需要中文再翻）。
2. **UI = 应用内开关**：`meta/settings` 文档存 `{lang: "zh"|"en"}`，Riverpod 监听，
   三端同步；首页 AppBar 一个「中/EN」按钮。无设置时缺省 zh（单用户，用户母语中文）。
3. **UI 文案 = 轻量自制 L10n 表**（非 gen-l10n/ARB）：`app/lib/l10n.dart` 一个类
   两个实例（zh/en），`ref.watch(l10nProvider)` 取表；热重载即时、单点修改。

## 数据模型增量（全部向后兼容，旧文档缺字段时兜底另一语言）

| 集合 | 新字段 | 写入方 |
|------|--------|--------|
| briefs | `markdownEn` | daily_brief 双语 prompt |
| chats | `answerEn` | chat 双语 prompt |
| suggestions | `rationaleEn` | advisor JSON 增键；海龟英文模板 |
| analyses | `sectionsZh: {key: text}` | translate job 增量 merge |
| meta/settings | `lang` | App 开关 |
| jobs | type=`translate`, `analysisId`, `sections[]` | App 翻译按钮 |

## 后端（assistant/）

- `lang.py`：`split_bilingual(text) -> (zh, en)`，解析 LLM 输出中的
  `===ZH===` / `===EN===` 分块；缺块时整文归入 zh、en 为空（旧行为兜底）。
- `daily_brief.py` / `chat.py`：prompt 要求两个语言版本一次输出，解析后分别存
  `markdownZh/markdownEn`、`answer/answerEn`。
- `advisor.py`：JSON 增加 `rationaleEn` 键。
- `strategies/turtle.py`：`Signal.reason_en` 英文模板；`engine.py` 落库 `rationaleEn`。
- `translate.py`：`translate_sections(store, llm, analysis_id, sections)` —
  逐段翻译（quick LLM），`store.merge_analysis_sections_zh()` 增量写回；
  已有译文的段跳过（幂等）。
- `jobs.py`：路由 `translate` job → translate_fn；`runner.py` 接线（复用 brief 的 llm）。

## App（Flutter）

- `l10n.dart`：`L10n` 类 + zh/en 实例 + `l10nProvider`（读 settings 流，缺省 zh）；
  `repo.setLang()` 写 `meta/settings`（merge）。
- AppBar 语言切换按钮（显示当前非活跃语言名，点按切换）。
- 全部 UI 硬编码中文 → `t.xxx`。TableCalendar 的星期/月份文案随语言。
- 模型：`Brief.markdownFor(lang)`、`ChatMessage.answerFor(lang)`、
  `Suggestion.rationaleFor(lang)`（缺失 → 另一语言原文，永不空白）；
  `Analysis.sectionsZh`。
- 分析详情/仪表盘：zh 模式下某段无译文 → 显示英文原文 + 段落级「翻译」按钮 →
  `repo.enqueueTranslate(analysisId, [sectionKey])`；job 完成后 Firestore 流自动刷新。
  注意：`analysis_insights.dart` 解析器**始终吃英文原文**（Rating/Action 标记），
  译文只用于展示，不参与解析。

## 测试

- Python：split_bilingual 解析（含缺块兜底）；brief/chat 双语落库；advisor rationaleEn；
  translate job 幂等 + merge；海龟英文模板。
- Flutter：L10n zh/en key 对齐（反射对比字段）；开关写 settings；三个 fallback helper；
  翻译按钮排 job；既有测试维持 zh 缺省全绿。

## 已知取舍

- 存量历史内容不批量补翻，靠兜底显示原语言 + 按需翻译。
- 翻译用 runner 的 quick LLM，质量满足研究参考即可。
- 日报结构标题（## 组合概览等）由 LLM 双语生成，非 UI 层翻译。
