"""Agent tools for DCF valuation.

The tool fetches financial data from yfinance, and the LLM supplies only
assumptions with source and rationale. This ensures deterministic, reproducible
valuations that can be unit-tested.
"""
from typing import Annotated
import json
import logging

from langchain_core.tools import tool
import yfinance as yf

from tradingagents.valuation.dcf import (
    DcfAssumptions,
    run_dcf,
    scenarios,
    sensitivity_table,
    implied_growth,
)
from tradingagents.dataflows.fred import get_macro_data
from tradingagents.dataflows.symbol_utils import normalize_symbol

logger = logging.getLogger(__name__)


def _fetch_financial_data(ticker: str) -> dict:
    """Fetch financial data from yfinance for DCF inputs."""
    canonical = normalize_symbol(ticker)
    yf_ticker = yf.Ticker(canonical)
    
    try:
        info = yf_ticker.info
        financials = yf_ticker.financials
        balance_sheet = yf_ticker.balance_sheet
        cashflow = yf_ticker.cashflow
        
        ttm_revenue = info.get('totalRevenue', 0)
        if ttm_revenue == 0 and not financials.empty and 'Total Revenue' in financials.index:
            ttm_revenue = financials.loc['Total Revenue'].iloc[0]
        
        operating_income = 0
        if not financials.empty and 'Operating Income' in financials.index:
            operating_income = financials.loc['Operating Income'].iloc[0]
        
        net_debt = 0
        if not balance_sheet.empty:
            total_debt = balance_sheet.loc['Total Debt'].iloc[0] if 'Total Debt' in balance_sheet.index else 0
            cash_equiv = balance_sheet.loc['Cash And Cash Equivalents'].iloc[0] if 'Cash And Cash Equivalents' in balance_sheet.index else 0
            net_debt = total_debt - cash_equiv
        
        shares = info.get('sharesOutstanding', 0)
        if shares == 0:
            shares = balance_sheet.loc['Ordinary Shares Number'].iloc[0] if not balance_sheet.empty and 'Ordinary Shares Number' in balance_sheet.index else 0
        
        current_price = info.get('currentPrice', info.get('regularMarketPrice', 0))
        
        return {
            'ttm_revenue': float(ttm_revenue) if ttm_revenue else 0,
            'operating_income': float(operating_income) if operating_income else 0,
            'net_cash': -float(net_debt) if net_debt else 0,
            'shares_outstanding': float(shares) if shares else 0,
            'current_price': float(current_price) if current_price else 0,
            'canonical': canonical,
        }
    except Exception as e:
        logger.warning(f"Failed to fetch financial data for {ticker}: {e}")
        return {
            'ttm_revenue': 0,
            'operating_income': 0,
            'net_cash': 0,
            'shares_outstanding': 0,
            'current_price': 0,
            'canonical': ticker,
            'error': str(e),
        }


@tool
def run_dcf_valuation(
    ticker: Annotated[str, "ticker symbol"],
    curr_date: Annotated[str, "current date, yyyy-mm-dd"],
    assumptions_json: Annotated[str, "JSON string with DCF assumptions and rationale"],
) -> str:
    """Run DCF valuation for an individual stock.
    
    This tool calculates intrinsic value using Discounted Cash Flow analysis.
    You must provide assumptions as a JSON string with this structure:
    
    {
        "revenue_growth_rates": [0.15, 0.12, 0.10, 0.08, 0.06, 0.05, 0.04, 0.04, 0.03, 0.03],
        "operating_margin_start": 0.25,
        "operating_margin_end": 0.30,
        "margin_convergence_years": 5,
        "tax_rate_effective": 0.15,
        "tax_rate_marginal": 0.25,
        "sales_to_capital": 2.0,
        "wacc_initial": 0.10,
        "wacc_stable": 0.08,
        "terminal_growth_rate": 0.03,
        "stable_roic": 0.15,
        "rationale": {
            "revenue_growth": "基于公司过去3年CAGR 18%及行业TAM增速10%，保守假设前5年15%→5%递减",
            "operating_margin": "当前TTM 25%，规模效应及成本优化可提升至30%",
            "wacc": "行业beta 1.2、无风险利率3%、市场风险溢价7%推算初期10%，成熟期降至8%",
            "terminal_growth": "略高于长期GDP增速2-3%，反映公司仍有轻微份额提升空间",
            "sales_to_capital": "历史资本周转率约2倍，符合软件行业轻资产特征"
        }
    }
    
    Revenue growth rates must be a list of 10 annual growth rates (as decimals).
    All percentage values should be decimals (e.g., 0.15 for 15%).
    The rationale field should cite sources (financial statements, industry reports).
    
    For index funds, ETFs, or bonds, do NOT call this tool - they don't require DCF.
    Only use for individual stocks in your circle of competence.
    
    The tool fetches actual financial data (TTM revenue, net cash, shares) from yfinance
    and combines it with your assumptions to produce bear/base/bull scenarios, a
    sensitivity table, and implied growth (reverse DCF).
    
    Args:
        ticker: Stock ticker symbol
        curr_date: Current date for getting risk-free rate
        assumptions_json: JSON string with all DCF assumptions and rationale
    
    Returns:
        A formatted report with three scenarios, sensitivity table, and implied growth
    """
    try:
        assumptions_dict = json.loads(assumptions_json)
    except json.JSONDecodeError as e:
        return f"❌ 无法解析 assumptions_json: {e}\n请提供有效的 JSON 字符串。"
    
    required_keys = [
        'revenue_growth_rates', 'operating_margin_start', 'operating_margin_end',
        'margin_convergence_years', 'tax_rate_effective', 'tax_rate_marginal',
        'sales_to_capital', 'wacc_initial', 'wacc_stable', 'terminal_growth_rate',
        'stable_roic'
    ]
    
    missing = [k for k in required_keys if k not in assumptions_dict]
    if missing:
        return f"❌ 缺少必需字段: {', '.join(missing)}"
    
    if len(assumptions_dict['revenue_growth_rates']) != 10:
        return f"❌ revenue_growth_rates 必须是10个年度增速的列表，当前长度：{len(assumptions_dict['revenue_growth_rates'])}"
    
    fin_data = _fetch_financial_data(ticker)
    
    if 'error' in fin_data:
        return f"❌ 无法获取 {ticker} 的财务数据：{fin_data['error']}"
    
    if fin_data['ttm_revenue'] <= 0:
        return f"❌ {ticker} 的 TTM 收入为 0 或无法获取，无法进行 DCF 估值。"
    
    if fin_data['shares_outstanding'] <= 0:
        return f"❌ {ticker} 的流通股数为 0 或无法获取，无法计算每股价值。"
    
    risk_free_rate = None
    try:
        fred_result = get_macro_data("10y_treasury", curr_date, look_back_days=5)
        import re
        match = re.search(r"\*\*Latest:\*\* ([\d.]+)", fred_result)
        if match:
            risk_free_rate = float(match.group(1)) / 100
    except Exception as e:
        logger.warning(f"Failed to fetch risk-free rate: {e}")
    
    base_assumptions = DcfAssumptions(
        base_revenue=fin_data['ttm_revenue'],
        revenue_growth_rates=assumptions_dict['revenue_growth_rates'],
        operating_margin_start=assumptions_dict['operating_margin_start'],
        operating_margin_end=assumptions_dict['operating_margin_end'],
        margin_convergence_years=assumptions_dict['margin_convergence_years'],
        tax_rate_effective=assumptions_dict['tax_rate_effective'],
        tax_rate_marginal=assumptions_dict['tax_rate_marginal'],
        sales_to_capital=assumptions_dict['sales_to_capital'],
        wacc_initial=assumptions_dict['wacc_initial'],
        wacc_stable=assumptions_dict['wacc_stable'],
        terminal_growth_rate=assumptions_dict['terminal_growth_rate'],
        stable_roic=assumptions_dict['stable_roic'],
        net_cash=fin_data['net_cash'],
        shares_outstanding=fin_data['shares_outstanding'],
        risk_free_rate=risk_free_rate,
        segment_revenues=assumptions_dict.get('segment_revenues', []),
    )
    
    scenario_results = scenarios(base_assumptions)
    sensitivity = sensitivity_table(base_assumptions, row_param='wacc', col_param='growth')
    
    implied_rev_growth = None
    if fin_data['current_price'] > 0:
        implied_rev_growth = implied_growth(
            fin_data['current_price'], 
            base_assumptions, 
            param='revenue_growth'
        )
    
    report_lines = [
        f"# DCF 估值报告：{ticker} ({fin_data['canonical']})",
        f"",
        f"**估值基准日**: {curr_date}",
        f"**当前股价**: ${fin_data['current_price']:.2f}" if fin_data['current_price'] > 0 else "**当前股价**: 无数据",
        f"**TTM 收入**: ${fin_data['ttm_revenue']:,.0f}",
        f"**流通股数**: {fin_data['shares_outstanding']:,.0f}",
        f"**净现金**: ${fin_data['net_cash']:,.0f}",
        f"",
        f"## 假设依据",
        f"",
    ]
    
    rationale = assumptions_dict.get('rationale', {})
    for key, value in rationale.items():
        report_lines.append(f"- **{key}**: {value}")
    
    report_lines.extend([
        f"",
        f"## 三情景估值",
        f"",
        f"| 情景 | 每股价值 | 相对现价 | 企业价值 | 终值占比 |",
        f"|------|----------|----------|----------|----------|",
    ])
    
    for scenario_name in ['熊市', '中性', '牛市']:
        key = {'熊市': 'bear', '中性': 'base', '牛市': 'bull'}[scenario_name]
        result = scenario_results[key]
        
        if fin_data['current_price'] > 0:
            rel_pct = (result.value_per_share - fin_data['current_price']) / fin_data['current_price'] * 100
            rel_str = f"{rel_pct:+.1f}%"
        else:
            rel_str = "N/A"
        
        report_lines.append(
            f"| {scenario_name} | ${result.value_per_share:.2f} | {rel_str} | "
            f"${result.enterprise_value / 1e9:.2f}B | {result.terminal_value_pct:.1f}% |"
        )
    
    if scenario_results['base'].warnings:
        report_lines.extend([
            f"",
            f"### ⚠️ 合理性警告",
            f"",
        ])
        for warning in scenario_results['base'].warnings:
            report_lines.append(f"- {warning}")
    
    report_lines.extend([
        f"",
        f"## 敏感性分析：WACC × 收入增速",
        f"",
        f"每股内在价值（单位：美元）",
        f"",
    ])
    
    header_row = "| WACC \\ 增速 |"
    for col_val in sensitivity['cols']:
        header_row += f" {col_val*100:.1f}% |"
    report_lines.append(header_row)
    report_lines.append("|" + "---|" * (len(sensitivity['cols']) + 1))
    
    for i, row_val in enumerate(sensitivity['rows']):
        row_str = f"| {row_val*100:.2f}% |"
        for val in sensitivity['values'][i]:
            is_base = (abs(row_val - base_assumptions.wacc_initial) < 0.001 and 
                      abs(sensitivity['cols'][sensitivity['values'][i].index(val)] - 
                          sum(base_assumptions.revenue_growth_rates)/len(base_assumptions.revenue_growth_rates)) < 0.001)
            if is_base:
                row_str += f" **${val:.2f}** |"
            else:
                row_str += f" ${val:.2f} |"
        report_lines.append(row_str)
    
    report_lines.extend([
        f"",
        f"## 反向 DCF",
        f"",
    ])
    
    if implied_rev_growth is not None:
        margin_of_safety = (scenario_results['base'].value_per_share - fin_data['current_price']) / scenario_results['base'].value_per_share * 100 if scenario_results['base'].value_per_share > 0 else 0
        
        report_lines.extend([
            f"当前股价 ${fin_data['current_price']:.2f} 隐含的**平均年收入增速**约为 **{implied_rev_growth*100:.1f}%**。",
            f"",
            f"中性情景价值 ${scenario_results['base'].value_per_share:.2f}，安全边际：**{margin_of_safety:+.1f}%**。",
        ])
    else:
        report_lines.append(f"无法计算隐含增速（当前价格可能过高或 DCF 参数范围外）。")
    
    report_lines.extend([
        f"",
        f"---",
        f"",
        f"**重要提示**：DCF 估值对假设高度敏感，仅作参考，不构成投资建议。个股须在能力圈内、有安全边际时才考虑买入。",
    ])
    
    return "\n".join(report_lines)
