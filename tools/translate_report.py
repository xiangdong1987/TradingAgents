#!/usr/bin/env python3
"""把一份已生成的 TradingAgents 报告翻译成另一种语言。

复用 .env 里已经配好的 LLM（OpenAI 兼容端点 / OpenAI / DeepSeek …），
逐文件按段落切块并发翻译，保持 markdown 结构、数字和代码不变，
输出到一个平行目录，之后可以直接喂给 report2pdf.py。

用法：
    translate_report.py <报告目录> --to English
    translate_report.py ~/.tradingagents/logs/AAPL/2026-07-31 --to English -o /tmp/aapl_en

输出目录结构与输入一致（reports/*.md 或 1_analysts/ 等阶段树），
所以：
    report2pdf.py /tmp/aapl_en --lang en -o ~/Desktop/AAPL_EN.pdf
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

try:
    from dotenv import load_dotenv
    from openai import OpenAI
except ImportError:
    sys.exit("缺少依赖：pip install openai python-dotenv")

REPO_ENV = Path(__file__).resolve().parent.parent / ".env"

SYSTEM = (
    "You are a professional financial translator. Translate the user's markdown "
    "into {target}, preserving meaning, tone and analytical nuance.\n"
    "Hard rules:\n"
    "1. Preserve markdown structure EXACTLY — heading levels, bullet/number markers, "
    "table pipes and alignment rows, bold/italic markers, blockquotes, horizontal rules.\n"
    "2. Never alter numbers, dates, percentages, currency amounts, tickers, or the contents "
    "of `inline code` and fenced code blocks.\n"
    "3. Use standard financial-industry terminology in the target language "
    "(e.g. 市盈率 -> P/E ratio, 建仓 -> build a position, 止损 -> stop-loss, "
    "超配 -> Overweight, 回撤 -> drawdown).\n"
    "4. Translate every line. Do not summarize, expand, comment, or add a preamble.\n"
    "5. Output ONLY the translated markdown — no ``` wrapper around the whole thing, "
    "no 'Here is the translation'."
)

CHUNK_CHARS = 3500


def split_markdown(text: str, limit: int = CHUNK_CHARS) -> list[str]:
    """按空行切块，遇到围栏代码块保持完整，尽量在标题前断开。"""
    blocks, buf, fence = [], [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        # 非代码块内的标题：作为新块的起点
        if not fence and line.startswith("#") and buf and sum(map(len, buf)) > limit * 0.5:
            blocks.append("\n".join(buf))
            buf = []
        buf.append(line)
        if not fence and sum(map(len, buf)) > limit and line.strip() == "":
            blocks.append("\n".join(buf))
            buf = []
    if buf:
        blocks.append("\n".join(buf))
    return [b for b in blocks if b.strip()] or [text]


def make_client() -> tuple[OpenAI, str]:
    load_dotenv(REPO_ENV)
    provider = os.getenv("TRADINGAGENTS_LLM_PROVIDER", "openai")
    key = (
        os.getenv("OPENAI_COMPATIBLE_API_KEY")
        or os.getenv("OPENAI_API_KEY")
        or os.getenv("DEEPSEEK_API_KEY")
        or "sk-noop"
    )
    base = os.getenv("TRADINGAGENTS_LLM_BACKEND_URL") or None
    model = os.getenv("TRADINGAGENTS_QUICK_THINK_LLM") or os.getenv(
        "TRADINGAGENTS_DEEP_THINK_LLM", "gpt-4o-mini"
    )
    if not base and provider == "openai_compatible":
        sys.exit("provider=openai_compatible 但没设 TRADINGAGENTS_LLM_BACKEND_URL")
    return OpenAI(api_key=key, base_url=base), model


def translate_chunk(client: OpenAI, model: str, text: str, target: str, retries: int = 2) -> str:
    for attempt in range(retries + 1):
        try:
            r = client.chat.completions.create(
                model=model,
                max_tokens=8000,
                messages=[
                    {"role": "system", "content": SYSTEM.format(target=target)},
                    {"role": "user", "content": text},
                ],
            )
            out = (r.choices[0].message.content or "").strip()
            if out:
                # 个别模型会把整段包进 ```markdown ... ```
                m = re.fullmatch(r"```(?:markdown|md)?\n(.*)\n```", out, re.S)
                return m.group(1) if m else out
        except Exception as e:
            if attempt == retries:
                print(f"    ! 翻译失败，保留原文：{type(e).__name__}: {str(e)[:120]}", file=sys.stderr)
        # 失败重试
    return text


def translate_file(client: OpenAI, model: str, src: Path, dst: Path, target: str,
                   workers: int) -> tuple[int, int]:
    chunks = split_markdown(src.read_text(encoding="utf-8"))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        parts = list(pool.map(lambda c: translate_chunk(client, model, c, target), chunks))
    out = "\n".join(parts)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(out, encoding="utf-8")
    return len(chunks), len(out)


def main() -> None:
    ap = argparse.ArgumentParser(description="翻译 TradingAgents 报告")
    ap.add_argument("path", help="报告目录（含 reports/ 或阶段树）")
    ap.add_argument("--to", default="English", help="目标语言，默认 English")
    ap.add_argument("-o", "--output", help="输出目录，默认在原目录旁加语言后缀")
    ap.add_argument("-j", "--jobs", type=int, default=6, help="并发块数，默认 6")
    args = ap.parse_args()

    root = Path(args.path).expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"不是目录：{root}")
    files = sorted(p for p in root.rglob("*.md") if p.is_file() and p.stat().st_size)
    if not files:
        sys.exit(f"{root} 下没有 .md")

    suffix = re.sub(r"\W+", "", args.to).lower()[:8]
    out_root = Path(args.output).expanduser() if args.output else root.parent / f"{root.name}_{suffix}"

    client, model = make_client()
    print(f"模型 {model} → {args.to}    {len(files)} 个文件 → {out_root}")

    for f in files:
        rel = f.relative_to(root)
        n, size = translate_file(client, model, f, out_root / rel, args.to, args.jobs)
        print(f"  ✓ {rel}  ({n} 块 → {size} chars)")

    print(f"\n完成：{out_root}")


if __name__ == "__main__":
    main()
