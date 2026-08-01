// app/lib/data/symbol_search.dart
/// Offline US ticker search backing the add-watch / add-position
/// autocomplete. The index is a bundled NASDAQ symbol directory
/// (assets/us_symbols.csv, `SYMBOL,Name` per line) plus a curated map of
/// Chinese aliases for well-known tickers, so "苹果" finds AAPL.
library;

import 'package:flutter/services.dart' show rootBundle;

class SymbolEntry {
  const SymbolEntry({required this.symbol, required this.name, this.alias = ''});

  final String symbol;
  final String name;
  final String alias; // Chinese alias(es), empty for most tickers

  @override
  String toString() => '$symbol — $name';
}

/// 常用美股中文别名（只覆盖高频标的；搜不到别名时永远可以直接输代码/英文名）。
const Map<String, String> zhAliases = {
  'AAPL': '苹果',
  'MSFT': '微软',
  'NVDA': '英伟达',
  'TSLA': '特斯拉',
  'GOOGL': '谷歌',
  'GOOG': '谷歌',
  'AMZN': '亚马逊',
  'META': '脸书 Meta',
  'NFLX': '奈飞',
  'TSM': '台积电',
  'BABA': '阿里巴巴',
  'JD': '京东',
  'PDD': '拼多多',
  'BIDU': '百度',
  'NTES': '网易',
  'BILI': '哔哩哔哩',
  'NIO': '蔚来',
  'LI': '理想汽车',
  'XPEV': '小鹏汽车',
  'INTC': '英特尔',
  'AMD': '超微 AMD',
  'MU': '美光',
  'AVGO': '博通',
  'QCOM': '高通',
  'ORCL': '甲骨文',
  'CRM': '赛富时',
  'ADBE': '奥多比',
  'KO': '可口可乐',
  'PEP': '百事',
  'MCD': '麦当劳',
  'SBUX': '星巴克',
  'NKE': '耐克',
  'DIS': '迪士尼',
  'BA': '波音',
  'JPM': '摩根大通',
  'GS': '高盛',
  'V': '维萨 Visa',
  'MA': '万事达',
  'BRK': '伯克希尔',
  'XOM': '埃克森美孚',
  'WMT': '沃尔玛',
  'COST': '开市客',
  'PFE': '辉瑞',
  'JNJ': '强生',
  'UNH': '联合健康',
  'SPY': '标普500 ETF',
  'QQQ': '纳指100 ETF',
  'VOO': '先锋标普500 ETF',
};

/// 米兰交易所（Borsa Italiana，Yahoo `.MI` 后缀）常用标的：FTSE MIB 成分股 +
/// 常见 UCITS ETF。全部经 yfinance 实测可取行情（2026-08）。
const List<SymbolEntry> milanEntries = [
  SymbolEntry(symbol: 'ENEL.MI', name: 'Enel S.p.A.', alias: '意大利国家电力'),
  SymbolEntry(symbol: 'ENI.MI', name: 'Eni S.p.A.', alias: '埃尼石油'),
  SymbolEntry(symbol: 'ISP.MI', name: 'Intesa Sanpaolo', alias: '联合圣保罗银行'),
  SymbolEntry(symbol: 'UCG.MI', name: 'UniCredit', alias: '裕信银行'),
  SymbolEntry(symbol: 'STLAM.MI', name: 'Stellantis N.V.', alias: '斯泰兰蒂斯'),
  SymbolEntry(symbol: 'RACE.MI', name: 'Ferrari N.V.', alias: '法拉利'),
  SymbolEntry(symbol: 'STMMI.MI', name: 'STMicroelectronics', alias: '意法半导体'),
  SymbolEntry(symbol: 'G.MI', name: 'Assicurazioni Generali', alias: '忠利保险'),
  SymbolEntry(symbol: 'TIT.MI', name: 'Telecom Italia', alias: '意大利电信'),
  SymbolEntry(symbol: 'LDO.MI', name: 'Leonardo S.p.A.', alias: '莱昂纳多'),
  SymbolEntry(symbol: 'PST.MI', name: 'Poste Italiane', alias: '意大利邮政'),
  SymbolEntry(symbol: 'MB.MI', name: 'Mediobanca'),
  SymbolEntry(symbol: 'BMED.MI', name: 'Banca Mediolanum'),
  SymbolEntry(symbol: 'BAMI.MI', name: 'Banco BPM'),
  SymbolEntry(symbol: 'BPE.MI', name: 'BPER Banca'),
  SymbolEntry(symbol: 'MONC.MI', name: 'Moncler', alias: '盟可睐'),
  SymbolEntry(symbol: 'CPR.MI', name: 'Davide Campari-Milano', alias: '金巴利'),
  SymbolEntry(symbol: 'A2A.MI', name: 'A2A S.p.A.'),
  SymbolEntry(symbol: 'TRN.MI', name: 'Terna'),
  SymbolEntry(symbol: 'SRG.MI', name: 'Snam'),
  SymbolEntry(symbol: 'PRY.MI', name: 'Prysmian'),
  SymbolEntry(symbol: 'TEN.MI', name: 'Tenaris'),
  SymbolEntry(symbol: 'SPM.MI', name: 'Saipem'),
  SymbolEntry(symbol: 'AMP.MI', name: 'Amplifon'),
  SymbolEntry(symbol: 'DIA.MI', name: 'DiaSorin'),
  SymbolEntry(symbol: 'FBK.MI', name: 'FinecoBank'),
  SymbolEntry(symbol: 'HER.MI', name: 'Hera'),
  SymbolEntry(symbol: 'IG.MI', name: 'Italgas'),
  SymbolEntry(symbol: 'INW.MI', name: 'Infrastrutture Wireless Italiane'),
  SymbolEntry(symbol: 'IVG.MI', name: 'Iveco Group', alias: '依维柯'),
  SymbolEntry(symbol: 'NEXI.MI', name: 'Nexi'),
  SymbolEntry(symbol: 'PIRC.MI', name: 'Pirelli & C.', alias: '倍耐力'),
  SymbolEntry(symbol: 'REC.MI', name: 'Recordati'),
  SymbolEntry(symbol: 'AZM.MI', name: 'Azimut Holding'),
  SymbolEntry(symbol: 'BGN.MI', name: 'Banca Generali'),
  SymbolEntry(symbol: 'UNI.MI', name: 'Unipol Gruppo'),
  SymbolEntry(symbol: 'ERG.MI', name: 'ERG S.p.A.'),
  SymbolEntry(symbol: 'IP.MI', name: 'Interpump Group'),
  SymbolEntry(symbol: 'BZU.MI', name: 'Buzzi'),
  SymbolEntry(symbol: 'BC.MI', name: 'Brunello Cucinelli'),
  SymbolEntry(symbol: 'IOT.MI', name: 'Seco S.p.A.'),
  SymbolEntry(symbol: 'VUAA.MI', name: 'Vanguard S&P 500 UCITS ETF (Acc)', alias: '标普500 ETF'),
  SymbolEntry(symbol: 'VWCE.MI', name: 'Vanguard FTSE All-World UCITS ETF', alias: '全球股票 ETF'),
  SymbolEntry(symbol: 'SWDA.MI', name: 'iShares Core MSCI World UCITS ETF', alias: '全球发达市场 ETF'),
  SymbolEntry(symbol: 'EIMI.MI', name: 'iShares Core MSCI EM IMI UCITS ETF', alias: '新兴市场 ETF'),
  SymbolEntry(symbol: 'CSSPX.MI', name: 'iShares Core S&P 500 UCITS ETF', alias: '标普500 ETF'),
  SymbolEntry(symbol: 'SGLD.MI', name: 'Invesco Physical Gold ETC', alias: '黄金 ETC'),
];

class SymbolIndex {
  SymbolIndex(this._entries);

  final List<SymbolEntry> _entries;

  static SymbolIndex? instance;

  /// Loads (and caches) the bundled index. Safe to call repeatedly; widget
  /// tests may pre-seed [instance] with [SymbolIndex.fromCsvString] instead.
  static Future<SymbolIndex> load() async {
    if (instance != null) return instance!;
    final csv = await rootBundle.loadString('assets/us_symbols.csv');
    return instance = SymbolIndex.fromCsvString(csv);
  }

  factory SymbolIndex.fromCsvString(String csv) {
    final entries = <SymbolEntry>[];
    for (final line in csv.split('\n')) {
      if (line.isEmpty) continue;
      final comma = line.indexOf(',');
      if (comma <= 0) continue;
      final symbol = line.substring(0, comma);
      var name = line.substring(comma + 1);
      if (name.startsWith('"') && name.endsWith('"') && name.length >= 2) {
        name = name.substring(1, name.length - 1).replaceAll('""', '"');
      }
      entries.add(SymbolEntry(
          symbol: symbol, name: name, alias: zhAliases[symbol] ?? ''));
    }
    entries.addAll(milanEntries);
    return SymbolIndex(entries);
  }

  /// Ranked search: exact symbol > symbol prefix > 中文别名 > 英文名包含。
  List<SymbolEntry> search(String query, {int limit = 8}) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final qUpper = q.toUpperCase();
    final qLower = q.toLowerCase();

    final exact = <SymbolEntry>[];
    final symPrefix = <SymbolEntry>[];
    final aliasHit = <SymbolEntry>[];
    final nameHit = <SymbolEntry>[];

    for (final e in _entries) {
      if (e.symbol == qUpper) {
        exact.add(e);
      } else if (e.symbol.startsWith(qUpper)) {
        symPrefix.add(e);
      } else if (e.alias.isNotEmpty && e.alias.contains(q)) {
        aliasHit.add(e);
      } else if (e.name.toLowerCase().contains(qLower)) {
        nameHit.add(e);
      }
      if (exact.length + symPrefix.length >= limit * 3) break;
    }
    symPrefix.sort((a, b) => a.symbol.length.compareTo(b.symbol.length));
    return [...exact, ...symPrefix, ...aliasHit, ...nameHit].take(limit).toList();
  }
}
