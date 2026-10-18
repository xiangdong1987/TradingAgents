"""Tests for investing principles loader."""
import tempfile
from pathlib import Path

import pytest

from assistant.principles import load_principles, load_principles_for_prompt


def test_load_principles_concise_includes_key_and_text():
    result = load_principles(concise=True)
    assert "白圭" in result
    assert "人弃我取" in result
    assert "人取我与" in result
    # 简明模式不包含详细的 application
    assert "应用：" not in result


def test_load_principles_full_includes_application():
    result = load_principles(concise=False)
    assert "白圭" in result
    assert "人弃我取" in result
    assert "应用：" in result or "application" in result.lower()


def test_load_principles_for_prompt_has_header():
    result = load_principles_for_prompt()
    assert "投资理念参考" in result
    assert "白圭" in result


def test_missing_file_returns_empty_string(monkeypatch):
    """缺失文件时降级返回空串，不中断流程。"""
    import assistant.principles as module
    monkeypatch.setattr(module, "_PRINCIPLES_FILE", Path("/nonexistent/path.yaml"))
    result = load_principles()
    assert result == ""


def test_malformed_yaml_returns_empty_string(tmp_path):
    """YAML 解析失败时降级返回空串。"""
    import assistant.principles as module
    bad_file = tmp_path / "bad.yaml"
    bad_file.write_text("{ invalid yaml content [")
    monkeypatch_obj = pytest.MonkeyPatch()
    monkeypatch_obj.setattr(module, "_PRINCIPLES_FILE", bad_file)
    result = load_principles()
    monkeypatch_obj.undo()
    assert result == ""


def test_empty_masters_returns_empty_string(tmp_path):
    """masters 列表为空时返回空串。"""
    import assistant.principles as module
    empty_file = tmp_path / "empty.yaml"
    empty_file.write_text("masters: []")
    monkeypatch_obj = pytest.MonkeyPatch()
    monkeypatch_obj.setattr(module, "_PRINCIPLES_FILE", empty_file)
    result = load_principles()
    monkeypatch_obj.undo()
    assert result == ""


def test_guardrails_appear_in_concise_mode():
    result = load_principles(concise=True)
    assert "边界" in result or "硬性规则" in result


def test_principles_includes_baigui_core_concepts():
    """验证白圭的核心概念都在原则文本中。"""
    result = load_principles(concise=True)
    # 七个核心原则
    assert "人弃我取" in result
    assert "人取我与" in result
    assert "乐观时变" in result
    assert "留三成" in result or "不能先倒" in result
    assert "看对只算一半" in result
    assert "智勇仁强" in result
    assert "不把别人的情绪" in result


def test_load_principles_for_prompt_empty_on_missing_file(monkeypatch):
    """缺失文件时 load_principles_for_prompt 也返回空串。"""
    import assistant.principles as module
    monkeypatch.setattr(module, "_PRINCIPLES_FILE", Path("/nonexistent"))
    result = load_principles_for_prompt()
    assert result == ""
