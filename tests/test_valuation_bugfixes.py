"""Tests for bug fixes from end-to-end INTC run.

Tests:
1. Sensitivity table center cell matches base case
2. Net cash includes short-term investments
3. Bear scenario margin floor is documented
"""
import pytest

from tradingagents.valuation.dcf import (
    DcfAssumptions,
    run_dcf,
    sensitivity_table,
    scenarios,
)


def test_sensitivity_center_matches_base():
    """Sensitivity table center cell should exactly match base case valuation."""
    base = DcfAssumptions(
        base_revenue=50000.0,
        revenue_growth_rates=[0.12, 0.10, 0.08, 0.06, 0.05, 0.04, 0.03, 0.03, 0.02, 0.02],
        operating_margin_start=0.20,
        operating_margin_end=0.25,
        margin_convergence_years=5,
        tax_rate_effective=0.15,
        tax_rate_marginal=0.25,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=5000.0,
        shares_outstanding=1000.0,
        risk_free_rate=0.04,
    )
    
    base_result = run_dcf(base)
    base_value = base_result.value_per_share
    
    sensitivity = sensitivity_table(base, row_param='wacc', col_param='growth')
    
    center_row = 2
    center_col = 2
    center_value = sensitivity['values'][center_row][center_col]
    
    assert abs(center_value - base_value) < 0.01, (
        f"Center cell {center_value:.2f} should match base case {base_value:.2f}"
    )


def test_sensitivity_wacc_uses_both_initial_and_stable():
    """When varying WACC, should preserve the initial-stable spread."""
    base = DcfAssumptions(
        base_revenue=10000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    sensitivity = sensitivity_table(base, row_param='wacc', col_param='growth')
    
    assert abs(sensitivity['rows'][2] - base.wacc_initial) < 0.001
    
    lowest_wacc_value = sensitivity['values'][0][2]
    highest_wacc_value = sensitivity['values'][4][2]
    
    assert lowest_wacc_value > highest_wacc_value


def test_bear_scenario_margin_floor_documented():
    """Bear scenario should floor margins at 5% (documented behavior)."""
    base = DcfAssumptions(
        base_revenue=10000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.06,
        operating_margin_end=0.07,
        margin_convergence_years=5,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    results = scenarios(base)
    
    bear = results['bear'].assumptions
    
    assert bear.operating_margin_start == 0.05
    assert bear.operating_margin_end == 0.05


def test_bear_scenario_full_shift_when_margins_above_floor():
    """Bear scenario achieves full -3pp shift when base margins are >= 8%."""
    base = DcfAssumptions(
        base_revenue=10000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.25,
        margin_convergence_years=5,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    results = scenarios(base)
    
    bear = results['bear'].assumptions
    
    assert abs(bear.operating_margin_start - (base.operating_margin_start - 0.03)) < 0.001
    assert abs(bear.operating_margin_end - (base.operating_margin_end - 0.03)) < 0.001


def test_net_cash_calculation_structure():
    """Net cash should be cash + short-term investments - total debt.
    
    This is a structural test - the actual calculation happens in valuation_tools.py
    _fetch_financial_data, but we test that the DCF engine handles both positive
    and negative net cash correctly.
    """
    positive_net_cash = DcfAssumptions(
        base_revenue=10000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=5000.0,
        shares_outstanding=100.0,
    )
    
    negative_net_cash = DcfAssumptions(
        base_revenue=10000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=-5000.0,
        shares_outstanding=100.0,
    )
    
    pos_result = run_dcf(positive_net_cash)
    neg_result = run_dcf(negative_net_cash)
    
    assert pos_result.equity_value == pos_result.enterprise_value + 5000.0
    assert neg_result.equity_value == neg_result.enterprise_value - 5000.0
    
    assert pos_result.value_per_share > neg_result.value_per_share


def test_scenarios_docstring_mentions_floor():
    """scenarios() docstring should document the 5% margin floor."""
    import inspect
    
    docstring = inspect.getdoc(scenarios)
    
    assert "5%" in docstring
    assert "floor" in docstring.lower() or "floored" in docstring.lower()
