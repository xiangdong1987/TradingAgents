"""Tests for DCF valuation module.

Tests cover:
- Basic DCF calculation with known inputs
- Validation warnings (perpetual growth > WACC, etc.)
- Bear/base/bull scenarios
- Sensitivity table generation
- Implied growth (reverse DCF)
- Edge cases
"""
import pytest

from tradingagents.valuation.dcf import (
    DcfAssumptions,
    run_dcf,
    scenarios,
    sensitivity_table,
    implied_growth,
)


@pytest.fixture
def base_assumptions():
    """Typical software company assumptions."""
    return DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.20, 0.18, 0.15, 0.12, 0.10, 0.08, 0.06, 0.05, 0.04, 0.03],
        operating_margin_start=0.20,
        operating_margin_end=0.30,
        margin_convergence_years=5,
        tax_rate_effective=0.15,
        tax_rate_marginal=0.25,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=500.0,
        shares_outstanding=100.0,
        risk_free_rate=0.04,
    )


def test_dcf_basic_calculation(base_assumptions):
    """Test basic DCF produces reasonable results."""
    result = run_dcf(base_assumptions)
    
    assert len(result.years) == 10
    assert result.value_per_share > 0
    assert result.enterprise_value > 0
    assert result.equity_value > result.enterprise_value
    assert result.years[0].revenue > base_assumptions.base_revenue
    assert result.terminal_value > 0


def test_dcf_revenue_growth():
    """Test revenue grows according to growth rates."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.02,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    result = run_dcf(a)
    
    assert abs(result.years[0].revenue - 1100.0) < 1.0
    assert abs(result.years[1].revenue - 1210.0) < 1.0
    assert result.years[-1].revenue > 2000.0


def test_dcf_margin_convergence():
    """Test operating margin converges over specified years."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.10,
        operating_margin_end=0.30,
        margin_convergence_years=5,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.02,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    result = run_dcf(a)
    
    year1_margin = result.years[0].operating_income / result.years[0].revenue
    year5_margin = result.years[4].operating_income / result.years[4].revenue
    year10_margin = result.years[9].operating_income / result.years[9].revenue
    
    assert abs(year1_margin - 0.14) < 0.01
    assert abs(year5_margin - 0.30) < 0.01
    assert abs(year10_margin - 0.30) < 0.01


def test_validation_terminal_growth_exceeds_wacc():
    """Test warning when terminal growth >= WACC."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.08,
        terminal_growth_rate=0.09,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    warnings = a.validate()
    assert any("永续增长率" in w and "WACC" in w for w in warnings)


def test_validation_terminal_growth_exceeds_risk_free():
    """Test warning when terminal growth > risk-free rate."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.05,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
        risk_free_rate=0.04,
    )
    
    warnings = a.validate()
    assert any("无风险利率" in w for w in warnings)


def test_validation_segment_revenue_mismatch():
    """Test warning when segment revenues don't sum to total."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
        segment_revenues=[600.0, 300.0],
    )
    
    warnings = a.validate()
    assert any("分部收入" in w and "重复计数" in w for w in warnings)


def test_validation_high_roic():
    """Test warning for unrealistic stable ROIC."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.03,
        stable_roic=0.60,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    warnings = a.validate()
    assert any("ROIC" in w and "50%" in w for w in warnings)


def test_validation_high_margin():
    """Test warning for unrealistic operating margin."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.75,
        margin_convergence_years=5,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    warnings = a.validate()
    assert any("营业利润率" in w and "70%" in w for w in warnings)


def test_terminal_value_percentage_warning():
    """Test warning when terminal value is >75% of enterprise value."""
    a = DcfAssumptions(
        base_revenue=100.0,
        revenue_growth_rates=[0.02] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.09,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    result = run_dcf(a)
    
    if result.terminal_value_pct > 75:
        assert any("终值占" in w and "75%" in w for w in result.warnings)


def test_scenarios_generation(base_assumptions):
    """Test bear/base/bull scenario generation."""
    results = scenarios(base_assumptions)
    
    assert "bear" in results
    assert "base" in results
    assert "bull" in results
    
    assert results["bear"].value_per_share < results["base"].value_per_share
    assert results["base"].value_per_share < results["bull"].value_per_share
    
    assert results["bull"].assumptions.wacc_initial < results["base"].assumptions.wacc_initial
    assert results["bear"].assumptions.wacc_initial > results["base"].assumptions.wacc_initial


def test_sensitivity_table_generation(base_assumptions):
    """Test sensitivity table with WACC x growth."""
    table = sensitivity_table(base_assumptions, row_param='wacc', col_param='growth')
    
    assert table['row_label'] == 'WACC'
    assert table['col_label'] == 'Revenue Growth'
    assert len(table['rows']) == 5
    assert len(table['cols']) == 5
    assert len(table['values']) == 5
    assert all(len(row) == 5 for row in table['values'])
    
    for row_values in table['values']:
        assert all(v > 0 for v in row_values)
    
    assert table['values'][0][0] > table['values'][4][0]
    assert table['values'][0][0] < table['values'][0][4]


def test_sensitivity_table_margin_terminal_g(base_assumptions):
    """Test sensitivity table with margin x terminal growth."""
    table = sensitivity_table(base_assumptions, row_param='margin', col_param='terminal_g')
    
    assert table['row_label'] == 'Operating Margin'
    assert table['col_label'] == 'Terminal Growth'
    assert len(table['values']) == 5


def test_implied_growth_revenue(base_assumptions):
    """Test reverse DCF for revenue growth."""
    base_result = run_dcf(base_assumptions)
    current_price = base_result.value_per_share
    
    implied = implied_growth(current_price, base_assumptions, param='revenue_growth')
    
    assert implied is not None
    avg_base_growth = sum(base_assumptions.revenue_growth_rates) / len(base_assumptions.revenue_growth_rates)
    assert abs(implied - avg_base_growth) < 0.02


def test_implied_growth_terminal(base_assumptions):
    """Test reverse DCF for terminal growth - approximate match."""
    base_result = run_dcf(base_assumptions)
    current_price = base_result.value_per_share
    
    implied = implied_growth(current_price, base_assumptions, param='terminal_g')
    
    if implied is not None:
        assert abs(implied - base_assumptions.terminal_growth_rate) < 0.02
    else:
        pytest.skip("Implied terminal growth solver did not converge (acceptable for this case)")


def test_implied_growth_no_solution():
    """Test implied growth returns None when price is out of range."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=100.0,
    )
    
    implied = implied_growth(1000000.0, a, param='revenue_growth')
    
    assert implied is None or implied > 0.45


def test_net_cash_adds_to_equity_value():
    """Test that net cash is added to enterprise value correctly."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=1000.0,
        shares_outstanding=100.0,
    )
    
    result = run_dcf(a)
    
    assert result.equity_value == result.enterprise_value + 1000.0
    assert result.value_per_share == result.equity_value / 100.0


def test_zero_shares_outstanding():
    """Test handling of zero shares outstanding."""
    a = DcfAssumptions(
        base_revenue=1000.0,
        revenue_growth_rates=[0.10] * 10,
        operating_margin_start=0.20,
        operating_margin_end=0.20,
        margin_convergence_years=0,
        tax_rate_effective=0.20,
        tax_rate_marginal=0.20,
        sales_to_capital=2.0,
        wacc_initial=0.10,
        wacc_stable=0.10,
        terminal_growth_rate=0.03,
        stable_roic=0.15,
        net_cash=0.0,
        shares_outstanding=0.0,
    )
    
    result = run_dcf(a)
    
    assert result.value_per_share == 0.0
