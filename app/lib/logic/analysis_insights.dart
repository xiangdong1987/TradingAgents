// app/lib/logic/analysis_insights.dart
/// 从深度分析的 markdown sections 里提取可视化数据的纯函数层。
///
/// LLM 输出格式有波动：所有函数解析失败时返回 null/空集合，
/// 仪表盘按「缺数据整块隐藏」处理，绝不渲染坏数据。
library;

enum Tone { bullish, bearish, neutral }

class MdTable {
  const MdTable({required this.headers, required this.rows});
  final List<String> headers;
  final List<List<String>> rows;

  /// 第一个包含 [word] 的表头下标，找不到返回 -1。
  int col(String word) => headers.indexWhere((h) => h.contains(word));
}

class IndicatorSignal {
  const IndicatorSignal(
      {required this.name, required this.value, required this.signal, required this.tone});
  final String name;
  final String value; // 当前值，可能为空
  final String signal; // 信号/强度原文
  final Tone tone;
}

class LabeledValue {
  const LabeledValue({required this.label, required this.value, this.note});
  final String label;
  final String value;
  final String? note;
}

class PriceLevel {
  const PriceLevel({required this.label, required this.value});
  final String label;
  final double value;
}

// ---------------------------------------------------------------------------
// 评级
// ---------------------------------------------------------------------------

const ratingLabels = ['卖出', '减持', '持有', '增持', '买入'];

/// Sell/Underweight/Hold/Overweight/Buy → 0..4；容忍加粗、大小写、中文；
/// 认不出返回 null。
int? ratingIndex(String decision) {
  final d = decision.toLowerCase();
  if (d.contains('underweight') || d.contains('减持')) return 1;
  if (d.contains('overweight') || d.contains('增持')) return 3;
  if (d.contains('sell') || d.contains('卖出')) return 0;
  if (d.contains('buy') || d.contains('买入')) return 4;
  if (d.contains('hold') || d.contains('持有')) return 2;
  return null;
}

String ratingZh(int index) => ratingLabels[index.clamp(0, 4)];

// ---------------------------------------------------------------------------
// **Key**: value 解析
// ---------------------------------------------------------------------------

/// 依次尝试 [keys]，返回第一个命中的值（同一行内、去掉加粗标记）。
/// 兼容 `**Key**: v` 与 `**Key:** v` 两种加粗形态，冒号全半角均可。
String? kvValue(String md, List<String> keys) {
  for (final key in keys) {
    final k = RegExp.escape(key);
    for (final pattern in [
      '\\*\\*$k\\*\\*\\s*[:：]\\s*(.+)',
      '\\*\\*$k\\s*[:：]\\s*\\*\\*\\s*(.+)',
    ]) {
      final m = RegExp(pattern, caseSensitive: false).firstMatch(md);
      if (m != null) {
        final v = stripMdMarks(m.group(1)!).trim();
        if (v.isNotEmpty) return v;
      }
    }
  }
  return null;
}

/// `Score: 5.0/10` → 5.0
double? sentimentScore(String md) {
  final m = RegExp(r'Score[:：]?\s*([\d.]+)\s*/\s*10').firstMatch(md);
  return m == null ? null : double.tryParse(m.group(1)!);
}

// ---------------------------------------------------------------------------
// markdown 表格
// ---------------------------------------------------------------------------

bool _isTableLine(String line) => line.trimLeft().startsWith('|');

bool _isSeparatorLine(String line) {
  if (!_isTableLine(line) || !line.contains('-')) return false;
  final cells = _splitCells(line);
  return cells.isNotEmpty &&
      cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c.replaceAll(' ', '')));
}

List<String> _splitCells(String line) {
  final parts = line.trim().split('|');
  // 首尾的 | 产生空串，去掉；中间的空单元格保留。
  if (parts.isNotEmpty && parts.first.trim().isEmpty) parts.removeAt(0);
  if (parts.isNotEmpty && parts.last.trim().isEmpty) parts.removeLast();
  return [for (final p in parts) stripMdMarks(p).trim()];
}

List<MdTable> parseMdTables(String md) {
  final tables = <MdTable>[];
  final lines = md.split('\n');
  var i = 0;
  while (i < lines.length) {
    if (_isTableLine(lines[i]) &&
        i + 1 < lines.length &&
        _isSeparatorLine(lines[i + 1])) {
      final headers = _splitCells(lines[i]);
      final rows = <List<String>>[];
      var j = i + 2;
      while (j < lines.length && _isTableLine(lines[j]) && !_isSeparatorLine(lines[j])) {
        rows.add(_splitCells(lines[j]));
        j++;
      }
      if (rows.isNotEmpty) tables.add(MdTable(headers: headers, rows: rows));
      i = j;
    } else {
      i++;
    }
  }
  return tables;
}

// ---------------------------------------------------------------------------
// 技术指标信号
// ---------------------------------------------------------------------------

bool _isDash(String s) => s.isEmpty || s == '—' || s == '-' || s == '–';

/// market 报告末尾的「关键指标汇总表」→ 信号 chips。
/// 取最后一张同时含「指标」「信号」表头的表；
/// 无信号内容的行（收盘价、布林轨道等纯价位行）跳过，由价位标尺呈现。
List<IndicatorSignal> indicatorSignals(String marketMd) {
  final tables = parseMdTables(marketMd)
      .where((t) => t.col('指标') >= 0 && t.col('信号') >= 0)
      .toList();
  if (tables.isEmpty) return const [];
  final t = tables.last;
  final nameCol = t.col('指标');
  final signalCol = t.col('信号');
  final strengthCol = t.col('强度');
  var valueCol = t.col('当前值');
  if (valueCol < 0) valueCol = t.col('数值');

  final out = <IndicatorSignal>[];
  for (final row in t.rows) {
    String cell(int c) => c >= 0 && c < row.length ? row[c].trim() : '';
    final name = cell(nameCol);
    // 有强度列时以强度为准（信号列可能是「强阻力」这类价位描述）。
    final toneText = strengthCol >= 0 ? cell(strengthCol) : cell(signalCol);
    if (name.isEmpty || _isDash(toneText)) continue;
    final value = _isDash(cell(valueCol)) ? '' : cell(valueCol);
    out.add(IndicatorSignal(
        name: name, value: value, signal: toneText, tone: toneOf(toneText)));
  }
  return out;
}

const _bullWords = ['偏多', '强多', '看涨', '看多', '多头', '金叉', 'bullish', '✅'];
const _bearWords = ['偏空', '看跌', '空头', '死叉', '偏弱', 'bearish', '⚠️'];

Tone toneOf(String text) {
  final t = text.toLowerCase();
  final bulls = _bullWords.where(t.contains).length;
  final bears = _bearWords.where(t.contains).length;
  if (bulls > bears) return Tone.bullish;
  if (bears > bulls) return Tone.bearish;
  return Tone.neutral;
}

// ---------------------------------------------------------------------------
// 基本面要点
// ---------------------------------------------------------------------------

/// fundamentals 里第一张「指标 + 数值」表 → 估值指标行（最多 [max] 行）。
List<LabeledValue> fundamentalMetrics(String fundamentalsMd, {int max = 10}) {
  final tables = parseMdTables(fundamentalsMd);
  for (final t in tables) {
    final nameCol = t.col('指标');
    var valueCol = t.col('数值');
    if (valueCol < 0) valueCol = t.col('当前值');
    if (nameCol < 0 || valueCol < 0) continue;
    var noteCol = t.col('评估');
    if (noteCol < 0) noteCol = t.col('分析');
    if (noteCol < 0) noteCol = t.col('说明');

    final out = <LabeledValue>[];
    for (final row in t.rows) {
      String cell(int c) => c >= 0 && c < row.length ? row[c].trim() : '';
      final label = cell(nameCol);
      final value = cell(valueCol);
      if (label.isEmpty || _isDash(value)) continue;
      final note = cell(noteCol);
      out.add(LabeledValue(label: label, value: value, note: note.isEmpty ? null : note));
      if (out.length >= max) break;
    }
    if (out.isNotEmpty) return out;
  }
  return const [];
}

// ---------------------------------------------------------------------------
// 价位标尺
// ---------------------------------------------------------------------------

const _levelAliases = <String, List<String>>{
  '现价': ['收盘价', '现价', '当前价'],
  '10日线': ['10日EMA', '10 EMA', '10日均线', '10EMA'],
  '50日线': ['50日SMA', '50 SMA', '50日均线', '50SMA'],
  '200日线': ['200日SMA', '200 SMA', '200日均线', '200SMA'],
  '布林上轨': ['布林上轨'],
  '布林中轨': ['布林中轨'],
  '布林下轨': ['布林下轨'],
};

double? _firstNumber(String s) {
  final m = RegExp(r'(\d[\d,]*\.?\d*)').firstMatch(s);
  return m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', ''));
}

/// 从 market 指标表 + traderPlan 的入场/止损里收集关键价位。
/// 若能定位现价，会丢弃与现价偏差 3 倍以上的解析噪声。
List<PriceLevel> priceLevels({required String market, required String traderPlan}) {
  final found = <String, double>{};

  for (final t in parseMdTables(market)) {
    final nameCol = t.col('指标');
    var valueCol = t.col('当前值');
    if (valueCol < 0) valueCol = t.col('数值');
    if (nameCol < 0 || valueCol < 0) continue;
    for (final row in t.rows) {
      if (nameCol >= row.length || valueCol >= row.length) continue;
      final name = row[nameCol];
      final value = _firstNumber(row[valueCol]);
      if (value == null) continue;
      for (final e in _levelAliases.entries) {
        if (e.value.any(name.contains)) {
          found.putIfAbsent(e.key, () => value);
          break;
        }
      }
    }
  }

  final entry = kvValue(traderPlan, ['Entry Price', '入场价']);
  final stop = kvValue(traderPlan, ['Stop Loss', '止损']);
  if (entry != null && _firstNumber(entry) != null) {
    found.putIfAbsent('入场', () => _firstNumber(entry)!);
  }
  if (stop != null && _firstNumber(stop) != null) {
    found.putIfAbsent('止损', () => _firstNumber(stop)!);
  }

  final now = found['现价'];
  final out = <PriceLevel>[
    for (final e in found.entries)
      if (now == null || (e.value > now / 3 && e.value < now * 3))
        PriceLevel(label: e.key, value: e.value),
  ];
  out.sort((a, b) => a.value.compareTo(b.value));
  return out;
}

// ---------------------------------------------------------------------------
// 文本清理与摘要
// ---------------------------------------------------------------------------

/// 去掉辩论记录里的 `Bull Analyst:` / `Aggressive Analyst:` 等发言人前缀。
String cleanDebate(String md) => md
    .replaceAll(RegExp(r'^\s*\w+ Analyst\s*[:：]\s*', multiLine: true), '')
    .trim();

/// 去掉加粗/斜体/行内代码标记（保留文字本身）。
String stripMdMarks(String s) => s
    .replaceAll('**', '')
    .replaceAll('__', '')
    .replaceAll('`', '')
    .replaceAll(RegExp(r'^\s*[*_]|[*_]\s*$'), '');

/// 提取适合卡片摘要的纯文本：跳过表格/分隔线/代码围栏，
/// 去 markdown 标记，按句子边界截到 [maxChars] 左右。
String excerpt(String md, {int maxChars = 120}) {
  final buf = StringBuffer();
  for (final raw in md.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || _isTableLine(line) || line.startsWith('```')) continue;
    if (RegExp(r'^[-=*_]{3,}$').hasMatch(line)) continue;
    var text = line
        .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
        .replaceFirst(RegExp(r'^(\d+[.、]|[-*•+])\s+'), '');
    text = stripMdMarks(text).trim();
    if (text.isEmpty) continue;
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(text);
    if (buf.length >= maxChars * 2) break; // 原料够了
  }

  final full = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (full.length <= maxChars) return full;

  // 按句子边界累计到 maxChars。
  final pieces = full.split(RegExp(r'(?<=[。！？!?；;])'));
  final out = StringBuffer();
  for (final p in pieces) {
    if (out.isNotEmpty && out.length + p.length > maxChars) break;
    out.write(p);
    if (out.length >= maxChars) break;
  }
  var result = out.toString().trim();
  if (result.isEmpty || result.length > maxChars * 1.4) {
    result = full.substring(0, maxChars);
  }
  return result.length < full.length ? '$result…' : result;
}
