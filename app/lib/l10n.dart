// app/lib/l10n.dart
/// 轻量双语文案表：一个类两个 const 实例（zh/en），`ref.watch(l10nProvider)` 取用。
/// 带参数的文案用方法（内部 switch code）。股票中文搜索别名不在此表（任何语言可用）。
library;

class L10n {
  const L10n(this.code);

  final String code; // 'zh' | 'en'

  bool get isZh => code == 'zh';

  // ---- 通用 ----
  String get appTitle => isZh ? '理财助手' : 'Wealth Assistant';
  String get cancel => isZh ? '取消' : 'Cancel';
  String get save => isZh ? '保存' : 'Save';
  String get add => isZh ? '添加' : 'Add';
  String get delete => isZh ? '删除' : 'Delete';
  String get retry => isZh ? '重试' : 'Retry';
  String get copied => isZh ? '已复制' : 'Copied';
  String loadFailed(Object e) => isZh ? '加载失败：$e' : 'Load failed: $e';

  // ---- 底部导航 ----
  String get tabToday => isZh ? '今日' : 'Today';
  String get tabWatch => isZh ? '自选' : 'Watchlist';
  String get tabPortfolio => isZh ? '持仓' : 'Portfolio';
  String get tabChat => isZh ? '问答' : 'Chat';
  String get tabHistory => isZh ? '历史' : 'History';

  // ---- 登录 ----
  String get email => isZh ? '邮箱' : 'Email';
  String get password => isZh ? '密码' : 'Password';
  String get signIn => isZh ? '登录' : 'Sign in';
  String get signInFailed => isZh ? '登录失败' : 'Sign-in failed';
  String signInError(Object e) => isZh ? '登录失败: $e' : 'Sign-in failed: $e';
  String authError(Object e) => isZh ? '认证出错: $e' : 'Auth error: $e';
  String get signOut => isZh ? '退出登录' : 'Sign out';
  String get signOutConfirm => isZh
      ? '确定退出登录吗？下次进来需要重新输入密码。'
      : 'Sign out? You will need to enter your password again next time.';

  // ---- 今日 tab ----
  String get totalValue => isZh ? '总市值' : 'Total value';
  String get pnlFloating => isZh ? '浮动盈亏' : 'Unrealized P&L';
  String get cash => isZh ? '现金' : 'Cash';
  String get cashTapHint => isZh ? '现金（点卡片编辑）' : 'Cash (tap card to edit)';
  String dailyBriefTitle(String date) =>
      isZh ? '每日投资日报 · $date' : 'Daily brief · $date';
  String get noBriefYet => isZh
      ? '还没有日报。runner 会在交易日收盘后生成第一份。'
      : 'No brief yet. The runner writes the first one after the next market close.';
  String get pendingSuggestions => isZh ? '待处理建议' : 'Pending suggestions';
  String get noPendingSuggestions => isZh ? '暂无待处理建议' : 'No pending suggestions';
  String get turtleScan => isZh ? '🐢 海龟扫描' : '🐢 Turtle scan';
  String get turtleScanning => isZh ? '🐢 扫描中' : '🐢 Scanning';
  String get turtleScanQueued => isZh
      ? '海龟扫描已排队，跑完建议会出现在这里'
      : 'Turtle scan queued; suggestions will appear here when done';
  String get strategyScan => isZh ? '策略扫描' : 'Strategy scan';

  // ---- 任务/Runner 状态 ----
  String get jobQueued => isZh ? '排队中' : 'Queued';
  String jobElapsed(int mins) => isZh ? '已 $mins 分钟' : '$mins min in';
  String get jobDailyBrief => isZh ? '日报生成' : 'Daily brief';
  String jobDeepAnalysis(String ticker) =>
      isZh ? '$ticker 深度分析' : '$ticker deep analysis';
  String get jobRefreshQuotes => isZh ? '行情刷新' : 'Quote refresh';
  String get jobChat => isZh ? '问答回复' : 'Chat reply';
  String get jobTranslate => isZh ? '翻译' : 'Translation';
  String get runnerOnline => isZh ? 'Runner 在线' : 'Runner online';
  String get runnerNotStarted => isZh ? 'Runner 未启动' : 'Runner not started';
  String runnerOffline(int mins) => isZh
      ? 'Runner 离线 · 最后活跃 $mins 分钟前'
      : 'Runner offline · last seen ${mins}m ago';
  String get jobWaitsForRunner =>
      isZh ? '任务将等待 runner 启动' : 'Job will wait for the runner to start';

  // ---- 日历 ----
  String get dowMon => isZh ? '一' : 'M';
  String get dowTue => isZh ? '二' : 'T';
  String get dowWed => isZh ? '三' : 'W';
  String get dowThu => isZh ? '四' : 'T';
  String get dowFri => isZh ? '五' : 'F';
  String get dowSat => isZh ? '六' : 'S';
  String get dowSun => isZh ? '日' : 'S';
  String get evEarnings => isZh ? '财报' : 'Earnings';
  String get evExDividend => isZh ? '除息' : 'Ex-div';
  String get evDividendPay => isZh ? '派息' : 'Dividend';

  // ---- 建议卡 ----
  String targetWeight(String pct) => isZh ? '目标仓位 $pct%' : 'Target weight $pct%';
  String get accept => isZh ? '采纳' : 'Accept';
  String get dismiss => isZh ? '忽略' : 'Dismiss';
  String get accepted => isZh ? '已采纳' : 'Accepted';
  String get dismissed => isZh ? '已忽略' : 'Dismissed';
  String get pendingStatus => isZh ? '待处理' : 'Pending';
  String acceptTitle(String ticker, String action) =>
      isZh ? '采纳建议：$ticker $action' : 'Accept: $ticker $action';
  String get recordTradeHint => isZh
      ? '可顺手记录实际成交（可选）：'
      : 'Optionally record the actual trade:';
  String get shares => isZh ? '股数' : 'Shares';
  String get priceLabel => isZh ? '成交价' : 'Price';
  String get acceptOnly => isZh ? '仅标记采纳' : 'Accept only';
  String get acceptWithTrade => isZh ? '记录成交并采纳' : 'Record trade & accept';
  String get turtleSource => isZh ? '🐢 海龟' : '🐢 Turtle';

  // ---- 自选 tab ----
  String get watchEmpty =>
      isZh ? '自选列表为空，点右下角添加' : 'Watchlist empty — tap + to add';
  String get addWatch => isZh ? '添加自选' : 'Add to watchlist';
  String get tickerFieldHint =>
      isZh ? '代码或名称（如 AAPL / 苹果）' : 'Ticker or name (e.g. AAPL / Apple)';
  String get analyzeNow => isZh ? '立即分析' : 'Analyze now';
  String get analyze => isZh ? '分析' : 'Analyze';
  String get reAnalyze => isZh ? '重新分析' : 'Re-analyze';
  String get analyzing => isZh ? '分析中' : 'Analyzing';
  String get analyzingEllipsis => isZh ? '分析中…' : 'Analyzing…';
  String get weeklyAuto => isZh ? '每周自动分析' : 'Weekly auto-analysis';
  String get weeklyLabel => isZh ? '每周分析' : 'Weekly';
  String get manualAnalysis => isZh ? '手动分析' : 'Manual';
  String queued(String ticker) => isZh ? '$ticker 已排队' : '$ticker queued';
  String deleted(String ticker) => isZh ? '已删除 $ticker' : 'Removed $ticker';
  String get bondNoDeep => isZh ? '单只债券暂不支持深度分析' : 'Deep analysis not supported for single bonds';
  String get quoteRefreshRequested => isZh
      ? '已请求刷新行情，处理完成后自动更新'
      : 'Quote refresh requested; updates automatically when done';
  String get refreshQuotes => isZh ? '刷新行情' : 'Refresh quotes';
  String get currentPrice => isZh ? '现价' : 'Price';
  String get noPrice => isZh ? '现价 —' : 'Price —';
  String get atCost => isZh ? '按成本计' : 'At cost';

  // ---- 持仓 tab ----
  String get noPositions => isZh ? '暂无持仓' : 'No positions';
  String get addFirstPosition => isZh ? '添加第一笔持仓' : 'Add your first position';
  String get newPosition => isZh ? '新增持仓' : 'New position';
  String editPosition(String ticker) =>
      isZh ? '编辑持仓：$ticker' : 'Edit position: $ticker';
  String get avgCost => isZh ? '成本' : 'Avg cost';
  String positionSubtitle(String shares, String cost) =>
      isZh ? '$shares 股 · 成本 $cost' : '$shares sh · cost $cost';
  String get editCash => isZh ? '编辑现金' : 'Edit cash';
  String get sell => isZh ? '卖出' : 'Sell';
  String get buy => isZh ? '买入' : 'Buy';
  String sellTitle(String ticker) => isZh ? '卖出 $ticker' : 'Sell $ticker';
  String get sellAll => isZh ? '全部' : 'All';
  String heldShares(String shares) => isZh ? '持有 $shares 股' : 'Holding $shares sh';
  String get realizedPnl => isZh ? '已实现盈亏' : 'Realized P&L';
  String get weight => isZh ? '权重' : 'Weight';
  String get concentration => isZh ? '集中度' : 'Concentration';
  String concentrationDetail(String top, String top3, String cash) => isZh
      ? '最大 $top% · 前三 $top3% · 现金 $cash%'
      : 'Top $top% · Top-3 $top3% · cash $cash%';
  String get tradeHistory => isZh ? '交易记录' : 'Trade history';
  String get cumulativeReturn => isZh ? '累计收益' : 'Cumulative return';
  String get unrealized => isZh ? '浮动' : 'Unrealized';
  String get realized => isZh ? '已实现' : 'Realized';
  String get incomeLabel => isZh ? '分红利息' : 'Income';
  String get recordIncome => isZh ? '记分红/利息' : 'Record income';
  String get incomeAmount => isZh ? '到账金额' : 'Amount received';
  String get incomeNote => isZh ? '备注（可选）' : 'Note (optional)';
  String get taxAmount => isZh ? '税额' : 'Tax';
  String get preTax => isZh ? '税前' : 'Pre-tax';
  String get afterTax => isZh ? '税后' : 'After tax';
  String get tax => isZh ? '税' : 'Tax';
  String proceedsHint(String principal, String netGain, String cash) => isZh
      ? '预计到账：本金 $principal + 税后盈利 $netGain = $cash'
      : 'Cash in: principal $principal + after-tax gain $netGain = $cash';
  String get lossNoTax => isZh ? '亏损不计税' : 'No tax on a loss';
  String get openedAt => isZh ? '建仓日（可选）' : 'Opened on (optional)';
  String get openedAtHint => isZh
      ? '填了之后分红只从这天起算'
      : 'Dividends are only counted from this date';
  String get edit => isZh ? '编辑' : 'Edit';
  String get deleteTradeTitle => isZh ? '删除这笔记录？' : 'Delete this entry?';
  String get deleteTradeBody => isZh
      ? '持仓与现金会同步回滚。'
      : 'The position and cash will be rolled back accordingly.';
  String get entryDeleted => isZh ? '已删除记录' : 'Entry deleted';
  String get entryUpdated => isZh ? '已更新记录' : 'Entry updated';
  String get creditCash => isZh ? '同时加进现金' : 'Also credit cash';
  String get incomeRecorded => isZh ? '已记录分红' : 'Income recorded';
  String get autoEstimate => isZh ? '自动估算' : 'auto';
  String get buyTitleNew => isZh ? '买入（记成交）' : 'Buy (record trade)';
  String get enterExisting => isZh ? '录入已有持仓' : 'Enter existing holding';
  String buyTitle(String ticker) => isZh ? '买入 $ticker' : 'Buy $ticker';
  String get noTrades => isZh ? '还没有成交记录' : 'No trades yet';
  String get tradeRecorded => isZh ? '已记录成交' : 'Trade recorded';
  String get tradeDate => isZh ? '成交日期' : 'Trade date';
  String get fromSuggestion => isZh ? '来自建议' : 'From suggestion';
  String deletePositionTitle(String ticker) =>
      isZh ? '删除 $ticker 持仓？' : 'Delete $ticker position?';
  String get irreversible => isZh ? '此操作不可恢复。' : 'This cannot be undone.';

  // ---- 问答 tab ----
  String get chatEmptyHint => isZh
      ? '问点什么吧——回答会结合你的实时持仓、现金与最近的深度分析结论。\n\n例：可口可乐和 Intesa 哪个更适合买入？'
      : 'Ask anything — answers use your live positions, cash and recent deep-analysis conclusions.\n\ne.g. Coca-Cola vs Intesa: which is the better buy?';
  String get chatInputHint => isZh ? '结合持仓问点什么…' : 'Ask with your portfolio in mind…';
  String get chatFailed => isZh ? '回答失败，请重新提问' : 'Answer failed — please ask again';

  // ---- 历史 tab / 分析详情 ----
  String get noAnalyses => isZh ? '还没有分析记录' : 'No analyses yet';
  String get noSuggestionHistory => isZh ? '还没有建议记录' : 'No suggestions yet';
  String get suggestionsSection => isZh ? '建议' : 'Suggestions';
  String get analysesSection => isZh ? '分析' : 'Analyses';
  String decision(String d) => isZh ? '决策：$d' : 'Decision: $d';
  String historyOf(String ticker) => isZh ? '$ticker 历史分析' : '$ticker history';
  String get historyRatings => isZh ? '历史评级 · 点开看当次报告' : 'Past ratings · tap for the report';
  String analysisDay(String date, String rel) =>
      isZh ? '分析日 $date$rel' : 'Trade date $date$rel';
  String get relToday => isZh ? ' · 今天' : ' · today';
  String relDaysAgo(int days) => isZh ? ' · $days天前' : ' · ${days}d ago';
  String get fullText => isZh ? '全文 ›' : 'Full text ›';
  String get translateSection => isZh ? '翻译此段' : 'Translate';
  String get translationQueued => isZh ? '翻译已排队，稍后自动显示' : 'Translation queued';
  String get justStarted => isZh ? '刚开始' : 'just started';

  // ---- 分析 section 标题 ----
  String get secMarket => isZh ? '市场技术面' : 'Market / technicals';
  String get secSentiment => isZh ? '市场情绪' : 'Sentiment';
  String get secNews => isZh ? '新闻' : 'News';
  String get secFundamentals => isZh ? '基本面' : 'Fundamentals';
  String get secBull => isZh ? '多方观点' : 'Bull case';
  String get secBear => isZh ? '空方观点' : 'Bear case';
  String get secResearchManager => isZh ? '研究主管结论' : 'Research manager';
  String get secTraderPlan => isZh ? '交易员计划' : 'Trader plan';
  String get secRiskAggressive => isZh ? '激进风控' : 'Aggressive risk view';
  String get secRiskConservative => isZh ? '保守风控' : 'Conservative risk view';
  String get secRiskNeutral => isZh ? '中性风控' : 'Neutral risk view';
  String get secPortfolioDecision => isZh ? '组合经理决定' : 'Portfolio decision';
  String get secFinalDecision => isZh ? '最终决策' : 'Final decision';
  String riskView(String title) => isZh ? '$title风控视角' : '$title risk view';

  // ---- 仪表盘 ----
  String get kpiRating => isZh ? '评级' : 'Rating';
  String get kpiConfidence => isZh ? '置信度' : 'Confidence';
  String confidenceSuffix(String c) => isZh ? ' · 置信度$c' : ' · confidence $c';
  String get keyLevels => isZh ? '关键价位' : 'Key levels';
  String get entryPrice => isZh ? '入场价' : 'Entry';
  String get entry => isZh ? '入场' : 'Entry';
  String get stopLoss => isZh ? '止损' : 'Stop';
  String get stopPrice => isZh ? '止损价' : 'Stop price';
  String get positionLabel => isZh ? '仓位' : 'Position';
  String sizingLine(String s) => isZh ? '仓位建议：$s' : 'Sizing: $s';
  String get direction => isZh ? '方向' : 'Direction';
  String get indicator => isZh ? '指标' : 'Indicator';
  String get valueCol => isZh ? '数值' : 'Value';
  String get currentValue => isZh ? '当前值' : 'Current';
  String get signal => isZh ? '信号' : 'Signal';
  String get strength => isZh ? '强度' : 'Strength';
  String get assessment => isZh ? '评估' : 'View';
  String get note => isZh ? '说明' : 'Note';
  String get fundamentalsKey => isZh ? '基本面要点' : 'Fundamentals highlights';
  String get analystOriginal => isZh ? '分析师原文' : 'Analyst original';
  String get fundamentalsOriginal => isZh ? '基本面原文' : 'Fundamentals original';
  String get newsOriginal => isZh ? '新闻面原文' : 'News original';
  String get tradePlan => isZh ? '交易计划' : 'Trade plan';
  String get timeHorizon => isZh ? '时间视野' : 'Horizon';
  String debateCount(int bulls, int flats, int bears) => isZh
      ? '$bulls 多 · $flats 平 · $bears 空'
      : '$bulls bull · $flats flat · $bears bear';
  String get analysisListTitle => isZh ? '历史分析列表' : 'All analyses';

  // ---- 仪表盘（补充） ----
  String get techSignals => isZh ? '技术信号' : 'Technical signals';
  String get marketOriginal => isZh ? '技术面原文' : 'Technicals original';
  String get sentimentOriginal => isZh ? '情绪面原文' : 'Sentiment original';
  String get riskAggressiveShort => isZh ? '激进' : 'Aggressive';
  String get riskNeutralShort => isZh ? '中性' : 'Neutral';
  String get riskConservativeShort => isZh ? '保守' : 'Conservative';

  /// 交易动作展示名：zh 用中文，en 用引擎原词（规范大写）；认不出原样返回。
  String actionName(String action) => switch (action.toLowerCase()) {
        'buy' => isZh ? '买入' : 'Buy',
        'sell' => isZh ? '卖出' : 'Sell',
        'hold' => isZh ? '持有' : 'Hold',
        'add' => isZh ? '加仓' : 'Add',
        'trim' => isZh ? '减仓' : 'Trim',
        _ => action,
      };

  /// 置信度展示名：zh 映射低/中/高，en 保留引擎原词；认不出原样返回。
  String confidenceName(String c) => !isZh
      ? c
      : switch (c.toLowerCase()) {
          'low' => '低',
          'medium' => '中',
          'high' => '高',
          _ => c,
        };
}

const l10nZh = L10n('zh');
const l10nEn = L10n('en');
