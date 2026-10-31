"""Deterministic DCF (Discounted Cash Flow) valuation engine.

This module provides pure-code DCF valuation with no LLM involvement, ensuring
reproducibility and transparency. The LLM supplies assumptions with rationale;
code fetches data and calculates results.

Design principles from summary_3fb1.md:
- No AI "reasonable ranges" or web searches for defaults
- Perpetual growth must be < WACC and <= risk-free rate
- Segment revenues must sum to total (no double counting)
- Terminal value > 75% of EV triggers a warning
- Bear/base/bull scenarios + sensitivity table + implied growth (reverse DCF)
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class DcfAssumptions:
    """All inputs for a DCF valuation run.
    
    LLM supplies these with source and rationale; code validates and calculates.
    """
    base_revenue: float
    revenue_growth_rates: list[float]
    operating_margin_start: float
    operating_margin_end: float
    margin_convergence_years: int
    tax_rate_effective: float
    tax_rate_marginal: float
    sales_to_capital: float
    wacc_initial: float
    wacc_stable: float
    terminal_growth_rate: float
    stable_roic: float
    net_cash: float
    shares_outstanding: float
    risk_free_rate: float | None = None
    segment_revenues: list[float] = field(default_factory=list)
    
    def validate(self) -> list[str]:
        """Run sanity checks; return list of warnings (empty if all pass)."""
        warnings: list[str] = []
        
        if self.terminal_growth_rate >= self.wacc_stable:
            warnings.append(
                f"永续增长率 {self.terminal_growth_rate:.2%} >= 稳定期 WACC "
                f"{self.wacc_stable:.2%}，会导致负终值或无穷值。"
            )
        
        if self.risk_free_rate is not None and self.terminal_growth_rate > self.risk_free_rate:
            warnings.append(
                f"永续增长率 {self.terminal_growth_rate:.2%} > 无风险利率 "
                f"{self.risk_free_rate:.2%}，意味着永续超越整体经济增长。"
            )
        
        if self.segment_revenues:
            segment_total = sum(self.segment_revenues)
            tolerance = abs(self.base_revenue * 0.01)
            if abs(segment_total - self.base_revenue) > tolerance:
                warnings.append(
                    f"分部收入合计 {segment_total:,.0f} ≠ 总收入 {self.base_revenue:,.0f}"
                    f"（差异 {abs(segment_total - self.base_revenue):,.0f}），存在遗漏或重复计数。"
                )
        
        if self.stable_roic > 0.50:
            warnings.append(
                f"稳定期 ROIC {self.stable_roic:.1%} > 50%，意味着永续超高回报（极少见）。"
            )
        
        if self.operating_margin_end > 0.70:
            warnings.append(
                f"目标营业利润率 {self.operating_margin_end:.1%} > 70%，远超大多数行业常态。"
            )
        
        return warnings


@dataclass(frozen=True)
class DcfYearResult:
    """Single year projection in the DCF."""
    year: int
    revenue: float
    operating_income: float
    tax: float
    nopat: float
    reinvestment: float
    fcff: float
    discount_factor: float
    pv: float


@dataclass(frozen=True)
class DcfResult:
    """Complete DCF valuation output."""
    assumptions: DcfAssumptions
    years: list[DcfYearResult]
    terminal_year: DcfYearResult
    terminal_value: float
    pv_operating_cashflows: float
    pv_terminal_value: float
    enterprise_value: float
    equity_value: float
    value_per_share: float
    warnings: list[str]
    
    @property
    def terminal_value_pct(self) -> float:
        """Terminal value as % of enterprise value."""
        if self.enterprise_value <= 0:
            return 0.0
        return self.pv_terminal_value / self.enterprise_value * 100


def run_dcf(a: DcfAssumptions) -> DcfResult:
    """Run a full DCF valuation with the given assumptions.
    
    Returns:
        DcfResult with year-by-year projections, terminal value, and per-share value.
    """
    warnings = a.validate()
    
    years: list[DcfYearResult] = []
    revenue = a.base_revenue
    
    num_years = len(a.revenue_growth_rates)
    
    for i, growth in enumerate(a.revenue_growth_rates):
        year_num = i + 1
        revenue = revenue * (1 + growth)
        
        if a.margin_convergence_years > 0 and year_num <= a.margin_convergence_years:
            progress = year_num / a.margin_convergence_years
            margin = a.operating_margin_start + (a.operating_margin_end - a.operating_margin_start) * progress
        else:
            margin = a.operating_margin_end
        
        operating_income = revenue * margin
        
        tax_rate = a.tax_rate_effective if year_num <= 3 else a.tax_rate_marginal
        tax = operating_income * tax_rate
        nopat = operating_income - tax
        
        if year_num < num_years:
            next_revenue = revenue * (1 + a.revenue_growth_rates[year_num])
        else:
            next_revenue = revenue * (1 + a.terminal_growth_rate)
        
        revenue_change = next_revenue - revenue
        reinvestment = revenue_change / a.sales_to_capital if a.sales_to_capital > 0 else 0
        
        fcff = nopat - reinvestment
        
        if year_num <= 5:
            wacc = a.wacc_initial
        elif year_num < 10:
            progress = (year_num - 5) / 5
            wacc = a.wacc_initial + (a.wacc_stable - a.wacc_initial) * progress
        else:
            wacc = a.wacc_stable
        
        discount_factor = (1 + wacc) ** year_num
        pv = fcff / discount_factor
        
        years.append(DcfYearResult(
            year=year_num,
            revenue=revenue,
            operating_income=operating_income,
            tax=tax,
            nopat=nopat,
            reinvestment=reinvestment,
            fcff=fcff,
            discount_factor=discount_factor,
            pv=pv,
        ))
    
    terminal_revenue = revenue * (1 + a.terminal_growth_rate)
    terminal_margin = a.operating_margin_end
    terminal_oi = terminal_revenue * terminal_margin
    terminal_tax = terminal_oi * a.tax_rate_marginal
    terminal_nopat = terminal_oi - terminal_tax
    
    terminal_reinvestment_rate = a.terminal_growth_rate / a.stable_roic if a.stable_roic > 0 else 0
    terminal_reinvestment = terminal_nopat * terminal_reinvestment_rate
    terminal_fcff = terminal_nopat - terminal_reinvestment
    
    terminal_value = terminal_fcff / (a.wacc_stable - a.terminal_growth_rate) if (a.wacc_stable - a.terminal_growth_rate) > 0 else 0
    
    if terminal_value < 0:
        warnings.append(
            f"终值为负数 {terminal_value:,.0f}，通常意味着 WACC < g（分母为负）或终值年 FCFF 为负。"
        )
        terminal_value = 0
    
    terminal_discount = (1 + a.wacc_stable) ** num_years
    pv_terminal = terminal_value / terminal_discount
    
    terminal_year_result = DcfYearResult(
        year=num_years + 1,
        revenue=terminal_revenue,
        operating_income=terminal_oi,
        tax=terminal_tax,
        nopat=terminal_nopat,
        reinvestment=terminal_reinvestment,
        fcff=terminal_fcff,
        discount_factor=terminal_discount,
        pv=0,
    )
    
    pv_operating = sum(y.pv for y in years)
    enterprise_value = pv_operating + pv_terminal
    
    if enterprise_value > 0 and pv_terminal / enterprise_value > 0.75:
        warnings.append(
            f"终值占企业价值 {pv_terminal / enterprise_value:.1%} > 75%，"
            f"模型对远期假设高度敏感，谨慎采信。"
        )
    
    equity_value = enterprise_value + a.net_cash
    value_per_share = equity_value / a.shares_outstanding if a.shares_outstanding > 0 else 0
    
    return DcfResult(
        assumptions=a,
        years=years,
        terminal_year=terminal_year_result,
        terminal_value=terminal_value,
        pv_operating_cashflows=pv_operating,
        pv_terminal_value=pv_terminal,
        enterprise_value=enterprise_value,
        equity_value=equity_value,
        value_per_share=value_per_share,
        warnings=warnings,
    )


def scenarios(base: DcfAssumptions) -> dict[str, DcfResult]:
    """Generate bear/base/bull scenarios around the base assumptions.
    
    Bear: -3pp growth, +1pp WACC, -3pp margin
    Base: as provided
    Bull: +3pp growth, -1pp WACC, +3pp margin
    
    Returns dict with keys 'bear', 'base', 'bull'.
    """
    bear_growth = [max(g - 0.03, -0.10) for g in base.revenue_growth_rates]
    bull_growth = [min(g + 0.03, 0.50) for g in base.revenue_growth_rates]
    
    bear_assumptions = DcfAssumptions(
        base_revenue=base.base_revenue,
        revenue_growth_rates=bear_growth,
        operating_margin_start=max(base.operating_margin_start - 0.03, 0.05),
        operating_margin_end=max(base.operating_margin_end - 0.03, 0.05),
        margin_convergence_years=base.margin_convergence_years,
        tax_rate_effective=base.tax_rate_effective,
        tax_rate_marginal=base.tax_rate_marginal,
        sales_to_capital=base.sales_to_capital,
        wacc_initial=min(base.wacc_initial + 0.01, 0.30),
        wacc_stable=min(base.wacc_stable + 0.01, 0.30),
        terminal_growth_rate=max(base.terminal_growth_rate - 0.01, 0.01),
        stable_roic=base.stable_roic,
        net_cash=base.net_cash,
        shares_outstanding=base.shares_outstanding,
        risk_free_rate=base.risk_free_rate,
        segment_revenues=base.segment_revenues,
    )
    
    bull_assumptions = DcfAssumptions(
        base_revenue=base.base_revenue,
        revenue_growth_rates=bull_growth,
        operating_margin_start=min(base.operating_margin_start + 0.03, 0.80),
        operating_margin_end=min(base.operating_margin_end + 0.03, 0.80),
        margin_convergence_years=base.margin_convergence_years,
        tax_rate_effective=base.tax_rate_effective,
        tax_rate_marginal=base.tax_rate_marginal,
        sales_to_capital=base.sales_to_capital,
        wacc_initial=max(base.wacc_initial - 0.01, 0.03),
        wacc_stable=max(base.wacc_stable - 0.01, 0.03),
        terminal_growth_rate=min(base.terminal_growth_rate + 0.01, base.wacc_stable - 0.02),
        stable_roic=base.stable_roic,
        net_cash=base.net_cash,
        shares_outstanding=base.shares_outstanding,
        risk_free_rate=base.risk_free_rate,
        segment_revenues=base.segment_revenues,
    )
    
    return {
        'bear': run_dcf(bear_assumptions),
        'base': run_dcf(base),
        'bull': run_dcf(bull_assumptions),
    }


def sensitivity_table(base: DcfAssumptions, row_param: str = 'wacc', 
                     col_param: str = 'growth') -> dict:
    """Generate a 5×5 sensitivity table varying two parameters.
    
    Args:
        base: Base case assumptions
        row_param: 'wacc' (varies WACC) or 'margin' (varies operating margin)
        col_param: 'growth' (varies revenue growth) or 'terminal_g' (varies terminal growth)
    
    Returns:
        Dict with 'rows', 'cols', 'values' (5×5 array of value per share)
    """
    if row_param == 'wacc':
        row_values = [
            base.wacc_initial - 0.015,
            base.wacc_initial - 0.0075,
            base.wacc_initial,
            base.wacc_initial + 0.0075,
            base.wacc_initial + 0.015,
        ]
        row_label = 'WACC'
    elif row_param == 'margin':
        row_values = [
            base.operating_margin_end - 0.04,
            base.operating_margin_end - 0.02,
            base.operating_margin_end,
            base.operating_margin_end + 0.02,
            base.operating_margin_end + 0.04,
        ]
        row_label = 'Operating Margin'
    else:
        raise ValueError(f"Unknown row_param: {row_param}")
    
    if col_param == 'growth':
        avg_growth = sum(base.revenue_growth_rates) / len(base.revenue_growth_rates)
        col_values = [
            avg_growth - 0.04,
            avg_growth - 0.02,
            avg_growth,
            avg_growth + 0.02,
            avg_growth + 0.04,
        ]
        col_label = 'Revenue Growth'
    elif col_param == 'terminal_g':
        col_values = [
            base.terminal_growth_rate - 0.02,
            base.terminal_growth_rate - 0.01,
            base.terminal_growth_rate,
            base.terminal_growth_rate + 0.01,
            base.terminal_growth_rate + 0.02,
        ]
        col_label = 'Terminal Growth'
    else:
        raise ValueError(f"Unknown col_param: {col_param}")
    
    values = []
    for row_val in row_values:
        row_results = []
        for col_val in col_values:
            test_assumptions = DcfAssumptions(
                base_revenue=base.base_revenue,
                revenue_growth_rates=[col_val if col_param == 'growth' else g 
                                     for g in base.revenue_growth_rates],
                operating_margin_start=base.operating_margin_start,
                operating_margin_end=row_val if row_param == 'margin' else base.operating_margin_end,
                margin_convergence_years=base.margin_convergence_years,
                tax_rate_effective=base.tax_rate_effective,
                tax_rate_marginal=base.tax_rate_marginal,
                sales_to_capital=base.sales_to_capital,
                wacc_initial=row_val if row_param == 'wacc' else base.wacc_initial,
                wacc_stable=row_val if row_param == 'wacc' else base.wacc_stable,
                terminal_growth_rate=col_val if col_param == 'terminal_g' else base.terminal_growth_rate,
                stable_roic=base.stable_roic,
                net_cash=base.net_cash,
                shares_outstanding=base.shares_outstanding,
                risk_free_rate=base.risk_free_rate,
                segment_revenues=base.segment_revenues,
            )
            
            result = run_dcf(test_assumptions)
            row_results.append(result.value_per_share)
        
        values.append(row_results)
    
    return {
        'row_label': row_label,
        'col_label': col_label,
        'rows': row_values,
        'cols': col_values,
        'values': values,
    }


def implied_growth(current_price: float, base: DcfAssumptions, 
                  param: str = 'revenue_growth') -> float | None:
    """Reverse DCF: what growth rate is implied by current price?
    
    Args:
        current_price: Current share price
        base: Base assumptions (all except the param to solve for)
        param: 'revenue_growth' or 'terminal_g'
    
    Returns:
        Implied growth rate (as decimal, e.g. 0.15 = 15%), or None if no solution
    """
    def value_at_growth(g: float) -> float:
        if param == 'revenue_growth':
            test_a = DcfAssumptions(
                base_revenue=base.base_revenue,
                revenue_growth_rates=[g] * len(base.revenue_growth_rates),
                operating_margin_start=base.operating_margin_start,
                operating_margin_end=base.operating_margin_end,
                margin_convergence_years=base.margin_convergence_years,
                tax_rate_effective=base.tax_rate_effective,
                tax_rate_marginal=base.tax_rate_marginal,
                sales_to_capital=base.sales_to_capital,
                wacc_initial=base.wacc_initial,
                wacc_stable=base.wacc_stable,
                terminal_growth_rate=base.terminal_growth_rate,
                stable_roic=base.stable_roic,
                net_cash=base.net_cash,
                shares_outstanding=base.shares_outstanding,
                risk_free_rate=base.risk_free_rate,
                segment_revenues=base.segment_revenues,
            )
        elif param == 'terminal_g':
            test_a = DcfAssumptions(
                base_revenue=base.base_revenue,
                revenue_growth_rates=base.revenue_growth_rates,
                operating_margin_start=base.operating_margin_start,
                operating_margin_end=base.operating_margin_end,
                margin_convergence_years=base.margin_convergence_years,
                tax_rate_effective=base.tax_rate_effective,
                tax_rate_marginal=base.tax_rate_marginal,
                sales_to_capital=base.sales_to_capital,
                wacc_initial=base.wacc_initial,
                wacc_stable=base.wacc_stable,
                terminal_growth_rate=g,
                stable_roic=base.stable_roic,
                net_cash=base.net_cash,
                shares_outstanding=base.shares_outstanding,
                risk_free_rate=base.risk_free_rate,
                segment_revenues=base.segment_revenues,
            )
        else:
            raise ValueError(f"Unknown param: {param}")
        
        return run_dcf(test_a).value_per_share
    
    low, high = 0.0, 0.50
    tolerance = 0.0001
    max_iterations = 50
    
    for _ in range(max_iterations):
        mid = (low + high) / 2
        mid_value = value_at_growth(mid)
        
        if abs(mid_value - current_price) < tolerance:
            return mid
        
        if mid_value > current_price:
            high = mid
        else:
            low = mid
        
        if high - low < 0.0001:
            break
    
    final_value = value_at_growth((low + high) / 2)
    if abs(final_value - current_price) / current_price < 0.10:
        return (low + high) / 2
    
    return None
