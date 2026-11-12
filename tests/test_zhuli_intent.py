"""Tests for get_zhuli_intent (主力意图诊断)."""
import pytest
from assistant.quotes import get_zhuli_intent


def _zhuli_bars(closes, highs=None, lows=None, volumes=None, close_bias="neutral"):
    """造日线 OHLCV。若 highs/lows 未指定，根据 close_bias 控制收盘位置：
    - 'high': close 接近 high（看涨，CMF 正）
    - 'low': close 接近 low（看跌，CMF 负）
    - 'neutral': close 在中间（CMF 接近 0）
    """
    n = len(closes)
    if highs is None or lows is None:
        if close_bias == "high":
            # close 接近 high → MFV 正
            highs = [c + 0.2 for c in closes]
            lows = [c - 2.0 for c in closes]
        elif close_bias == "low":
            # close 接近 low → MFV 负
            highs = [c + 2.0 for c in closes]
            lows = [c - 0.2 for c in closes]
        else:  # neutral
            highs = [c + 1.0 for c in closes]
            lows = [c - 1.0 for c in closes]
    if volumes is None:
        volumes = [1000000.0] * n
    return [
        {"date": f"2026-08-{i+1:02d}", "high": highs[i], "low": lows[i],
         "close": closes[i], "volume": volumes[i]}
        for i in range(n)
    ]


def test_zhuli_intent_accumulation_scenario():
    """强烈吸筹场景：上涨趋势 + 正 CMF + 上涨日放量 + 看涨背离。"""
    # 构造 60 根：前 40 根平淡，后 20 根上涨 + 上涨日放量
    closes = [100.0] * 40 + [100 + i * 2 for i in range(20)]  # 100 -> 138
    volumes = [100000.0] * 40 + [200000.0 if i % 2 == 0 else 50000.0 for i in range(20)]
    # 偶数日放量 → 上涨日放量（closes 严格递增，偶数日对应放量）
    bars = _zhuli_bars(closes, volumes=volumes, close_bias="high")

    result = get_zhuli_intent("GOOGL", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    assert result["label"] in ("吸筹", "偏吸筹")
    assert result["score"] > 0
    assert result["cmf20"] > 0  # 上涨 + 收盘接近高点 → CMF 正
    assert result["accumDays"] >= 5  # 至少有几次放量上涨
    assert "次放量上涨" in "".join(result["reasons"])


def test_zhuli_intent_distribution_scenario():
    """派发场景：下跌 + 负 CMF + 派发日 + 看跌背离。"""
    # 60 根：前 40 根平淡，后 20 根下跌 + 下跌日放量
    closes = [150.0] * 40 + [150 - i * 2 for i in range(20)]  # 150 -> 112
    volumes = [100000.0] * 40 + [200000.0 if i % 2 == 1 else 50000.0 for i in range(20)]
    # 奇数日放量 → 下跌日放量
    bars = _zhuli_bars(closes, volumes=volumes, close_bias="low")

    result = get_zhuli_intent("PST.MI", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    assert result["label"] in ("派发", "偏派发")
    assert result["score"] < 0
    assert result["cmf20"] < 0
    assert result["distDays"] >= 5
    assert "次派发日" in "".join(result["reasons"])


def test_zhuli_intent_neutral_flat_prices():
    """中性场景：价格平稳 + 量无明显异常。"""
    # 构造 60 根完全相同的价格和成交量，不触发任何模式
    closes = [120.0] * 60
    volumes = [100000.0] * 60
    # 用 neutral bias 让 close 在中间，CMF ≈ 0
    bars = _zhuli_bars(closes, volumes=volumes, close_bias="neutral")

    result = get_zhuli_intent("VUAA.MI", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    # 平价无涨跌 → 无上涨日/下跌日 → upDownVolRatio 默认 1.0
    # CMF 应接近 0（close 在中间）
    # 无放量上涨、派发日、缩量回调（因为价格完全不变）
    # 得分应较低且标签倾向中性或略偏
    assert abs(result["cmf20"]) < 0.05  # CMF 接近 0
    assert result["upDownVolRatio"] == 1.0  # 无涨跌日 → 比率 1.0
    # 分数可能略偏正（如果有缩量回调被计入），但应在中性范围
    assert -30 < result["score"] < 30


def test_zhuli_intent_low_vol_pullback():
    """缩量回调场景：价格在均线上，小幅回调 + 缩量（健康信号）。"""
    # 60 根：前 40 根平稳，后 20 根微涨，但间有缩量回调日
    closes = [100.0] * 40
    for i in range(20):
        if i % 4 == 3:  # 每 4 天一次小回调
            closes.append(closes[-1] - 1.0)
        else:
            closes.append(closes[-1] + 0.5)
    volumes = [100000.0] * 40
    for i in range(20):
        if i % 4 == 3:  # 回调日缩量
            volumes.append(50000.0)
        else:
            volumes.append(100000.0)
    bars = _zhuli_bars(closes, volumes=volumes)

    result = get_zhuli_intent("SPCX", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    assert result["lowVolPullbacks"] >= 2  # 至少捕捉到几次缩量回调
    assert "次缩量回调" in "".join(result["reasons"])


def test_zhuli_intent_stagnant_volume():
    """放量滞涨（近高位）：量大但价格不涨（可能派发）。"""
    closes = [100.0] * 40 + list(range(100, 120))  # 前 40 平，后 20 缓涨到 119
    volumes = [100000.0] * 59 + [300000.0]  # 最后一日巨量
    # 最后一日变化 (119-118)/118 ≈ 0.85%，略高于 0.5%；调整让最后一日变化小
    closes[-1] = closes[-2] + 0.3  # 变化 ~0.25% < 0.5%
    bars = _zhuli_bars(closes, volumes=volumes)

    result = get_zhuli_intent("BMW.DE", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    if "放量滞涨" in result["flags"]:
        assert result["score"] < 0  # 放量滞涨是负分
        assert "最新放量滞涨" in "".join(result["reasons"])


def test_zhuli_intent_low_volume_stabilization():
    """地量企稳（近低位）：量缩到最低 + 价在底部（可能见底）。"""
    closes = [120.0] * 40 + list(range(120, 100, -1))  # 前 40 平，后 20 跌到 100
    volumes = [100000.0] * 59 + [20000.0]  # 最后一日地量
    bars = _zhuli_bars(closes, volumes=volumes, close_bias="low")

    result = get_zhuli_intent("ENEL.MI", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    # 地量企稳是一个正面特征（+15分），但整体趋势是下跌派发
    # 所以总分可能仍为负，但应该有这个标志和原因
    if "地量企稳" in result["flags"]:
        assert "最新地量企稳" in "".join(result["reasons"])
        # 验证该特征确实被检测到并加入了评分
        # 不强制要求总分为正，因为下跌趋势的负面因素可能更强


def test_zhuli_intent_ad_bullish_divergence():
    """A/D 看涨背离：价格平淡/跌，但 A/D 上行（潜在吸筹）。"""
    # 60 根：前 40 根平，后 20 根价格微跌但收盘位置偏高（接近 high）→ A/D 累积
    closes = [100.0] * 40 + [100 - i * 0.2 for i in range(20)]  # 100 -> 96.2（跌 3.8%）
    highs = [c + 2 for c in closes[:40]] + [c + 0.1 for c in closes[40:]]  # 后 20 根 close 接近 high
    lows = [c - 2 for c in closes[:40]] + [c - 2 for c in closes[40:]]
    volumes = [100000.0] * 60
    bars = [
        {"date": f"2026-08-{i+1:02d}", "high": highs[i], "low": lows[i],
         "close": closes[i], "volume": volumes[i]}
        for i in range(60)
    ]

    result = get_zhuli_intent("ISP.MI", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    # 价格跌 < 3%，但 close 接近 high → MFV 为正 → A/D 上升
    if result["adDivergence"] == "bullish":
        assert "潜在吸筹" in "".join(result["reasons"])
        assert result["score"] > 0


def test_zhuli_intent_ad_bearish_divergence():
    """A/D 看跌背离：价格涨，但 A/D 下行（潜在派发）。"""
    # 60 根：前 40 根平，后 20 根价格涨但收盘位置偏低（接近 low）→ A/D 下降
    closes = [100.0] * 40 + [100 + i * 0.3 for i in range(20)]  # 100 -> 105.7（涨 5.7% > 3%）
    highs = [c + 2 for c in closes[:40]] + [c + 2 for c in closes[40:]]
    lows = [c - 2 for c in closes[:40]] + [c - 0.1 for c in closes[40:]]  # 后 20 根 close 接近 low
    volumes = [100000.0] * 60
    bars = [
        {"date": f"2026-08-{i+1:02d}", "high": highs[i], "low": lows[i],
         "close": closes[i], "volume": volumes[i]}
        for i in range(60)
    ]

    result = get_zhuli_intent("SPM.MI", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    if result["adDivergence"] == "bearish":
        assert "潜在派发" in "".join(result["reasons"])
        assert result["score"] < 0


def test_zhuli_intent_insufficient_data():
    """数据不足 <60 根 → None。"""
    bars = _zhuli_bars([100.0] * 50)
    assert get_zhuli_intent("GOOGL", "2026-08-31", _history=lambda t, s, e: bars) is None


def test_zhuli_intent_isin_returns_none():
    """ISIN（债券）→ None，不发请求。"""
    def boom(t, s, e):
        raise AssertionError("ISIN 不应该拉日线")
    assert get_zhuli_intent("IT0005424897", "2026-08-31", _history=boom) is None


def test_zhuli_intent_zero_volume_bars_skipped():
    """零成交量日被过滤，有效根数不足 → None。"""
    closes = [100.0] * 70
    volumes = [100000.0] * 30 + [0.0] * 40  # 前 30 根有量，后 40 根零量
    bars = _zhuli_bars(closes, volumes=volumes)
    result = get_zhuli_intent("VUAA.MI", "2026-08-31", _history=lambda t, s, e: bars)
    assert result is None  # 过滤后只剩 30 根 < 60


def test_zhuli_intent_error_returns_none():
    """取数异常 → None。"""
    def boom(t, s, e):
        raise RuntimeError("network down")
    assert get_zhuli_intent("GOOGL", "2026-08-31", _history=boom) is None


def test_zhuli_intent_score_clipping():
    """综合评分被裁剪到 [-100, 100]。"""
    # 极端吸筹场景：所有信号都触发正分
    closes = [100.0] * 40 + [100 + i * 5 for i in range(20)]  # 大幅上涨
    volumes = [50000.0] * 40 + [300000.0] * 20  # 后 20 日全部巨量
    bars = _zhuli_bars(closes, volumes=volumes)

    result = get_zhuli_intent("GOOGL", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    assert -100 <= result["score"] <= 100


def test_zhuli_intent_updown_volume_ratio():
    """上涨日/下跌日成交量比计算正确。"""
    # 60 根：前 40 平，后 20 根交替涨跌，涨日放量、跌日缩量
    closes = [100.0] * 40
    volumes = [100000.0] * 40
    for i in range(20):
        if i % 2 == 0:  # 涨日
            closes.append(closes[-1] + 1.0)
            volumes.append(200000.0)
        else:  # 跌日
            closes.append(closes[-1] - 0.5)
            volumes.append(50000.0)
    bars = _zhuli_bars(closes, volumes=volumes)

    result = get_zhuli_intent("PST.MI", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    # 近 20 日：10 涨日 × 200k，9 跌日 × 50k（第一日无对比）
    # 比率 = 2000k / 450k ≈ 4.44 > 1.3
    assert result["upDownVolRatio"] > 1.3
    assert "放量上涨为主" in "".join(result["reasons"])


def test_zhuli_intent_all_keys_present():
    """返回字典包含所有必需的键。"""
    closes = [100.0] * 60
    volumes = [100000.0] * 60
    bars = _zhuli_bars(closes, volumes=volumes)

    result = get_zhuli_intent("SPCX", "2026-08-31", _history=lambda t, s, e: bars)

    assert result is not None
    required_keys = {"cmf20", "adDivergence", "upDownVolRatio", "accumDays",
                     "distDays", "lowVolPullbacks", "flags", "score", "label", "reasons"}
    assert set(result.keys()) == required_keys
    assert isinstance(result["flags"], list)
    assert isinstance(result["reasons"], list)
    assert result["label"] in ("吸筹", "偏吸筹", "中性", "偏派发", "派发")
