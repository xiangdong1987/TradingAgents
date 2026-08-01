"""可插拔策略框架：注册表 + 纯函数策略接口。

新增一个策略 = 写一个模块（末尾调 ``register(...)``）+ 在本文件底部加一行
import。策略只做「bars + 持仓状态 → 信号」的纯计算，所有副作用（取行情、
重建单元账本、去重、写 suggestion）都在 ``engine.py``，保证策略可单测。
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable


@dataclass(frozen=True)
class Signal:
    """一条可执行建议：engine 会把它落成 suggestion 文档。"""
    action: str                 # buy | add | trim | sell
    price: float                # 信号价（当日收盘）
    reason: str                 # 中文模板理由，直接展示给用户
    shares: float | None = None
    stop: float | None = None
    meta: dict = field(default_factory=dict)


@dataclass
class ScanContext:
    """engine 为每个标的准备好的一切输入。bars 升序，最后一根是最新收盘。"""
    ticker: str
    bars: list[dict]            # [{date, high, low, close}]
    position: dict | None      # positions 文档（shares/avgCost），无持仓为 None
    units: list[dict]           # 单元账本 [{entry, shares, system, n}]，见 engine._rebuild_units
    portfolio_value: float      # 现金 + 全部持仓市值（advisor 同款简化：币种直加）
    cash: float
    params: dict                # 策略缺省 ⊕ meta/strategies 配置覆盖


@dataclass(frozen=True)
class Strategy:
    name: str                   # 配置键 / suggestion.source，如 "turtle"
    label: str                  # 展示名，如 "海龟(双系统)"
    defaults: dict
    scan: Callable[[ScanContext], list[Signal]]


REGISTRY: dict[str, Strategy] = {}


def register(strategy: Strategy) -> None:
    REGISTRY[strategy.name] = strategy


# import 即注册（新策略在下面追加一行）
from assistant.strategies import turtle  # noqa: E402,F401
