"""Tests for DCF valuation policy gates.

Tests check_valuation and check_trim_at_target functions.
"""
import pytest
from datetime import datetime, timedelta

from assistant import policy


def test_check_valuation_passes_for_core_layer():
    """Core/defensive layers skip valuation check."""
    p = policy.merged(None)
    
    result = policy.check_valuation(
        "VUAA.MI", 100.0, None, "2026-10-31", p
    )
    
    assert result is None


def test_check_valuation_blocks_missing_valuation():
    """Satellite stock with no valuation is blocked."""
    p = policy.merged(None)
    
    result = policy.check_valuation(
        "AAPL", 150.0, None, "2026-10-31", p
    )
    
    assert result is not None
    assert result.blocked
    assert result.binding == "valuation"
    assert "DCF 估值" in result.reason
    assert "没有自己的估值计算不动手" in result.reason


def test_check_valuation_blocks_missing_base_value():
    """Valuation without intrinsic_base is blocked."""
    p = policy.merged(None)
    valuation = {
        "intrinsic_bear": 100.0,
        "intrinsic_bull": 150.0,
        "valuation_date": "2026-10-31",
    }
    
    result = policy.check_valuation(
        "AAPL", 125.0, valuation, "2026-10-31", p
    )
    
    assert result is not None
    assert result.blocked


def test_check_valuation_blocks_stale_valuation():
    """Valuation older than maxAgeDays is blocked."""
    p = policy.merged({"valuationMaxAgeDays": 30})
    valuation = {
        "intrinsic_base": 150.0,
        "valuation_date": "2026-09-15",
    }
    
    result = policy.check_valuation(
        "AAPL", 125.0, valuation, "2026-10-31", p
    )
    
    assert result is not None
    assert result.blocked
    assert "过期" in result.reason


def test_check_valuation_blocks_insufficient_margin():
    """Price above safety margin line is blocked."""
    p = policy.merged({"minMarginOfSafetyPct": 25.0})
    valuation = {
        "intrinsic_base": 100.0,
        "valuation_date": "2026-10-31",
    }
    
    result = policy.check_valuation(
        "AAPL", 80.0, valuation, "2026-10-31", p
    )
    
    assert result is not None
    assert result.blocked
    assert "安全边际" in result.reason
    assert result.binding == "valuation"


def test_check_valuation_passes_sufficient_margin():
    """Price with adequate safety margin passes."""
    p = policy.merged({"minMarginOfSafetyPct": 25.0})
    valuation = {
        "intrinsic_base": 100.0,
        "valuation_date": "2026-10-31",
    }
    
    result = policy.check_valuation(
        "AAPL", 70.0, valuation, "2026-10-31", p
    )
    
    assert result is None


def test_check_valuation_custom_margin():
    """Custom margin of safety threshold."""
    p = policy.merged({"minMarginOfSafetyPct": 40.0})
    valuation = {
        "intrinsic_base": 100.0,
        "valuation_date": "2026-10-31",
    }
    
    result_fail = policy.check_valuation(
        "AAPL", 65.0, valuation, "2026-10-31", p
    )
    assert result_fail is not None
    assert result_fail.blocked
    
    result_pass = policy.check_valuation(
        "AAPL", 55.0, valuation, "2026-10-31", p
    )
    assert result_pass is None


def test_check_valuation_fresh_valuation():
    """Recent valuation passes age check."""
    p = policy.merged({"valuationMaxAgeDays": 100})
    valuation = {
        "intrinsic_base": 150.0,
        "valuation_date": "2026-10-01",
    }
    
    result = policy.check_valuation(
        "AAPL", 100.0, valuation, "2026-10-31", p
    )
    
    assert result is None


def test_check_trim_at_target_core_layer():
    """Core/defensive layers don't get trim hints."""
    p = policy.merged(None)
    valuation = {
        "intrinsic_bull": 200.0,
    }
    
    result = policy.check_trim_at_target("VUAA.MI", 190.0, valuation, p)
    
    assert result is None


def test_check_trim_at_target_no_valuation():
    """No valuation means no trim hint."""
    p = policy.merged(None)
    
    result = policy.check_trim_at_target("AAPL", 200.0, None, p)
    
    assert result is None


def test_check_trim_at_target_below_threshold():
    """Price below trim threshold returns no hint."""
    p = policy.merged({"trimAboveBullPct": 95.0})
    valuation = {
        "intrinsic_bull": 200.0,
    }
    
    result = policy.check_trim_at_target("AAPL", 180.0, valuation, p)
    
    assert result is None


def test_check_trim_at_target_above_threshold():
    """Price at/above trim threshold returns hint."""
    p = policy.merged({"trimAboveBullPct": 95.0})
    valuation = {
        "intrinsic_bull": 200.0,
    }
    
    result = policy.check_trim_at_target("AAPL", 195.0, valuation, p)
    
    assert result is not None
    assert "牛市估值" in result
    assert "trim" in result


def test_check_trim_at_target_custom_threshold():
    """Custom trim threshold percentage."""
    p = policy.merged({"trimAboveBullPct": 90.0})
    valuation = {
        "intrinsic_bull": 100.0,
    }
    
    result_below = policy.check_trim_at_target("AAPL", 85.0, valuation, p)
    assert result_below is None
    
    result_above = policy.check_trim_at_target("AAPL", 91.0, valuation, p)
    assert result_above is not None


def test_valuation_date_missing():
    """Valuation missing date field is blocked."""
    p = policy.merged(None)
    valuation = {
        "intrinsic_base": 150.0,
    }
    
    result = policy.check_valuation(
        "AAPL", 100.0, valuation, "2026-10-31", p
    )
    
    assert result is not None
    assert result.blocked
    assert "日期" in result.reason


def test_valuation_date_invalid_format():
    """Invalid date format is handled gracefully."""
    p = policy.merged(None)
    valuation = {
        "intrinsic_base": 150.0,
        "valuation_date": "invalid-date",
    }
    
    result = policy.check_valuation(
        "AAPL", 100.0, valuation, "2026-10-31", p
    )
    
    assert result is not None
    assert result.blocked


def test_policy_defaults_include_valuation_params():
    """Policy defaults include new valuation parameters."""
    assert "minMarginOfSafetyPct" in policy.DEFAULTS
    assert "valuationMaxAgeDays" in policy.DEFAULTS
    assert "trimAboveBullPct" in policy.DEFAULTS
    
    assert policy.DEFAULTS["minMarginOfSafetyPct"] == 25.0
    assert policy.DEFAULTS["valuationMaxAgeDays"] == 100
    assert policy.DEFAULTS["trimAboveBullPct"] == 95.0


def test_valuation_label_in_limit_labels():
    """Valuation binding has proper label."""
    zh, en = policy._LIMIT_LABELS["valuation"]
    
    assert "估值" in zh
    assert "安全边际" in zh
    assert "valuation" in en
    assert "margin of safety" in en
