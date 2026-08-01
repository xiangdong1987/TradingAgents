#!/usr/bin/env python3
"""把 TradingAgents 的 markdown 报告转成排版好的 PDF。

支持两种目录布局：

1. 运行时自动落盘（扁平）—— ~/.tradingagents/logs/<TICKER>/<DATE>/reports/
       market_report.md  sentiment_report.md  news_report.md
       fundamentals_report.md  investment_plan.md
       trader_investment_plan.md  final_trade_decision.md

2. CLI "Save report?" 导出（分阶段目录树）
       1_analysts/  2_research/  3_trading/  4_risk/  5_portfolio/
       complete_report.md

用法：
    report2pdf.py                     # 自动找最新一次运行
    report2pdf.py <目录>              # 指定 run 目录或 reports 目录
    report2pdf.py <目录> -o out.pdf   # 指定输出路径

渲染走 markdown -> HTML -> headless Chrome 打印，中文字体用系统 PingFang SC，
不需要 LaTeX / pandoc / wkhtmltopdf。
"""

from __future__ import annotations

import argparse
import html
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

try:
    import markdown
except ImportError:
    sys.exit("缺少依赖：pip install markdown")

DEFAULT_LOGS = Path.home() / ".tradingagents" / "logs"

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
]

# (相对路径, 阶段 key, 小节 key)。两种布局的候选路径都列出来，取存在的那个。
SECTION_SPEC: list[tuple[list[str], str, str]] = [
    (["reports/market_report.md", "1_analysts/market.md"], "analysts", "market"),
    (["reports/sentiment_report.md", "1_analysts/sentiment.md"], "analysts", "sentiment"),
    (["reports/news_report.md", "1_analysts/news.md"], "analysts", "news"),
    (["reports/fundamentals_report.md", "1_analysts/fundamentals.md"], "analysts", "fundamentals"),
    (["2_research/bull.md"], "research", "bull"),
    (["2_research/bear.md"], "research", "bear"),
    (["reports/investment_plan.md", "2_research/manager.md"], "research", "manager"),
    (["reports/trader_investment_plan.md", "3_trading/trader.md"], "trading", "trader"),
    (["4_risk/aggressive.md"], "risk", "aggressive"),
    (["4_risk/conservative.md"], "risk", "conservative"),
    (["4_risk/neutral.md"], "risk", "neutral"),
    (["reports/final_trade_decision.md", "5_portfolio/decision.md"], "portfolio", "decision"),
]

# 界面文案。正文语言由报告本身决定，这里只管封面/目录/标题这层壳。
STRINGS = {
    "zh": {
        "subtitle": "多智能体投研分析报告",
        "toc": "目录",
        "date": "分析日期", "generated": "生成时间",
        "source": "报告来源", "count": "章节数量",
        "disclaimer": "本报告由 LLM 多智能体框架自动生成，仅供研究参考，<b>不构成任何投资建议</b>。"
                      "结论会随模型、温度、数据质量与随机性波动，请以文中论据而非最终标签为准。",
        "stages": {"analysts": "一、分析师团队", "research": "二、研究团队辩论",
                   "trading": "三、交易团队", "risk": "四、风险管理评审",
                   "portfolio": "五、投资组合经理"},
        "sections": {"market": "技术面分析", "sentiment": "情绪面分析", "news": "新闻面分析",
                     "fundamentals": "基本面分析", "bull": "多头研究员", "bear": "空头研究员",
                     "manager": "研究经理裁决", "trader": "交易员方案", "aggressive": "激进派",
                     "conservative": "保守派", "neutral": "中立派", "decision": "最终决策"},
    },
    "en": {
        "subtitle": "Multi-Agent Investment Research Report",
        "toc": "Contents",
        "date": "Analysis date", "generated": "Generated",
        "source": "Source", "count": "Sections",
        "disclaimer": "This report was generated automatically by an LLM multi-agent framework "
                      "for research purposes only and <b>does not constitute investment advice</b>. "
                      "Conclusions vary with model, temperature, data quality and randomness — "
                      "weigh the reasoning in the text, not the final label.",
        "stages": {"analysts": "I. Analyst Team", "research": "II. Research Team Debate",
                   "trading": "III. Trading Team", "risk": "IV. Risk Management Review",
                   "portfolio": "V. Portfolio Manager"},
        "sections": {"market": "Market Analysis", "sentiment": "Sentiment Analysis",
                     "news": "News Analysis", "fundamentals": "Fundamentals Analysis",
                     "bull": "Bull Researcher", "bear": "Bear Researcher",
                     "manager": "Research Manager Verdict", "trader": "Trader Plan",
                     "aggressive": "Aggressive", "conservative": "Conservative",
                     "neutral": "Neutral", "decision": "Final Decision"},
    },
}

CSS = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }
* { box-sizing: border-box; }
body {
  font-family: "PingFang SC", "Hiragino Sans GB", "Heiti SC",
               -apple-system, "Helvetica Neue", Arial, sans-serif;
  font-size: 10.5pt; line-height: 1.75; color: #1a1a1a; margin: 0;
}
code, pre { font-family: "SF Mono", Menlo, Consolas, monospace; }

/* 封面 */
.cover { height: 245mm; display: flex; flex-direction: column;
         justify-content: center; page-break-after: always; }
.cover .kicker { font-size: 11pt; letter-spacing: .22em; color: #8a8a8a;
                 text-transform: uppercase; margin-bottom: 14mm; }
.cover h1 { font-size: 34pt; margin: 0 0 4mm; letter-spacing: -.01em; }
.cover .sub { font-size: 15pt; color: #555; margin: 0 0 16mm; font-weight: 400; }
.cover .meta { font-size: 10pt; color: #777; line-height: 2; border-top: 1px solid #e0e0e0;
               padding-top: 6mm; }
.cover .warn { margin-top: 14mm; font-size: 9pt; color: #9a5b00;
               background: #fff8e8; border-left: 3px solid #e0a33a;
               padding: 4mm 5mm; line-height: 1.6; }

/* 目录 */
.toc { page-break-after: always; }
.toc h2 { font-size: 17pt; margin: 0 0 8mm; padding-bottom: 3mm;
          border-bottom: 2px solid #1a1a1a; }
.toc .g { font-weight: 600; margin: 6mm 0 2mm; font-size: 11pt; }
.toc ul { list-style: none; padding-left: 6mm; margin: 0; }
.toc li { padding: 1.2mm 0; color: #444; font-size: 10pt; }

/* 正文 */
.stage { page-break-before: always; }
.stage > .stage-title { font-size: 19pt; margin: 0 0 7mm; padding-bottom: 3mm;
                        border-bottom: 2px solid #1a1a1a; }
.sec { margin-bottom: 9mm; }
.sec > .sec-title { font-size: 13pt; margin: 0 0 4mm; padding-left: 3mm;
                    border-left: 4px solid #3a6ea5; color: #23486e; }
.body h1 { font-size: 14pt; margin: 6mm 0 3mm; }
.body h2 { font-size: 12.5pt; margin: 5mm 0 2.5mm; }
.body h3, .body h4 { font-size: 11pt; margin: 4mm 0 2mm; }
.body p { margin: 0 0 3mm; }
.body ul, .body ol { margin: 0 0 3mm; padding-left: 7mm; }
.body li { margin-bottom: 1mm; }
.body strong { color: #000; }
.body blockquote { margin: 3mm 0; padding: 2mm 4mm; border-left: 3px solid #d0d0d0;
                   color: #555; background: #fafafa; }
.body table { border-collapse: collapse; width: 100%; margin: 3mm 0; font-size: 9.5pt; }
.body th, .body td { border: 1px solid #dcdcdc; padding: 1.8mm 3mm; text-align: left;
                     vertical-align: top; }
.body th { background: #f2f4f7; font-weight: 600; }
.body tr:nth-child(even) td { background: #fbfbfc; }
.body pre { background: #f6f7f9; border: 1px solid #e4e6ea; border-radius: 3px;
            padding: 3mm 4mm; overflow-x: auto; font-size: 8.5pt; line-height: 1.5; }
.body code { background: #f0f1f3; padding: .3mm 1.2mm; border-radius: 2px; font-size: 9pt; }
.body pre code { background: none; padding: 0; font-size: inherit; }
.body hr { border: none; border-top: 1px solid #e4e4e4; margin: 5mm 0; }
.body img { max-width: 100%; }

/* 避免标题落在页底 */
.sec > .sec-title, .body h1, .body h2, .body h3 { page-break-after: avoid; }
.body table, .body pre, blockquote { page-break-inside: avoid; }
"""


def find_chrome() -> str:
    for p in CHROME_CANDIDATES:
        if Path(p).exists():
            return p
    for name in ("google-chrome", "chromium", "chromium-browser"):
        found = shutil.which(name)
        if found:
            return found
    sys.exit(
        "找不到 Chrome / Chromium。请安装其中之一，或用 --html-only 只导出 HTML "
        "后自行用浏览器「打印为 PDF」。"
    )


def latest_run() -> Path:
    """~/.tradingagents/logs 下最近修改过、且真的有 .md 的那次运行目录。"""
    if not DEFAULT_LOGS.exists():
        sys.exit(f"找不到 {DEFAULT_LOGS} —— 先跑一次分析，或手动传入报告目录。")
    runs = [d for d in DEFAULT_LOGS.glob("*/*") if d.is_dir() and any(d.rglob("*.md"))]
    if not runs:
        sys.exit(f"{DEFAULT_LOGS} 下没有任何含 .md 的运行记录。")
    return max(runs, key=lambda d: d.stat().st_mtime)


def resolve_root(path: Path) -> Path:
    """允许用户传 run 目录、reports 目录，或导出的树根目录。"""
    if path.name == "reports" and path.is_dir():
        return path.parent  # SECTION_SPEC 里写的是 reports/xxx.md
    return path


def collect(root: Path) -> list[tuple[str, str, Path]]:
    out: list[tuple[str, str, Path]] = []
    for candidates, stage, title in SECTION_SPEC:
        for rel in candidates:
            f = root / rel
            if f.is_file() and f.read_text(encoding="utf-8").strip():
                out.append((stage, title, f))
                break
    return out


def render_md(text: str) -> str:
    return markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "sane_lists", "nl2br", "codehilite"],
        extension_configs={"codehilite": {"noclasses": True, "guess_lang": False}},
    )


def guess_meta(root: Path) -> tuple[str, str]:
    """从路径猜 (标的, 分析日期)。logs 布局是 .../<TICKER>/<DATE>/。"""
    parts = root.parts
    ticker, date = root.name, ""
    if len(parts) >= 2:
        parent = parts[-2]
        # <TICKER>/<YYYY-MM-DD>
        if len(root.name) == 10 and root.name[4] == "-":
            ticker, date = parent, root.name
        # 导出布局 <TICKER>_<YYYYmmdd_HHMMSS>
        elif "_" in root.name:
            head, _, tail = root.name.partition("_")
            ticker, date = head, tail
    return ticker, date


def build_html(root: Path, sections: list[tuple[str, str, Path]], lang: str = "zh") -> str:
    ticker, date = guess_meta(root)
    S = STRINGS[lang]
    stage_name = lambda k: S["stages"].get(k, k)
    sec_name = lambda k: S["sections"].get(k, k)

    # 目录
    toc_rows, seen = [], None
    for stage, title, _ in sections:
        if stage != seen:
            if seen is not None:
                toc_rows.append("</ul>")  # 不闭合会让 <ul> 层层嵌套，目录逐级缩进
            toc_rows.append(f'<div class="g">{html.escape(stage_name(stage))}</div><ul>')
            seen = stage
        toc_rows.append(f"<li>{html.escape(sec_name(title))}</li>")
    if seen is not None:
        toc_rows.append("</ul>")

    # 正文：同一阶段的小节合并进一个 .stage，阶段之间分页
    body, cur = [], None
    for stage, title, f in sections:
        if stage != cur:
            if cur is not None:
                body.append("</div>")
            body.append(
                f'<div class="stage"><div class="stage-title">'
                f"{html.escape(stage_name(stage))}</div>"
            )
            cur = stage
        body.append(
            f'<div class="sec"><div class="sec-title">{html.escape(sec_name(title))}</div>'
            f'<div class="body">{render_md(f.read_text(encoding="utf-8"))}</div></div>'
        )
    if cur is not None:
        body.append("</div>")

    return f"""<!doctype html>
<html lang="{'zh-CN' if lang == 'zh' else 'en'}"><head><meta charset="utf-8">
<title>TradingAgents — {html.escape(ticker)}</title>
<style>{CSS}</style></head><body>

<div class="cover">
  <div class="kicker">TradingAgents</div>
  <h1>{html.escape(ticker)}</h1>
  <div class="sub">{S["subtitle"]}</div>
  <div class="meta">
    {S["date"]}: {html.escape(date or "—")}<br>
    {S["generated"]}: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}<br>
    {S["source"]}: {html.escape(str(root))}<br>
    {S["count"]}: {len(sections)}
  </div>
  <div class="warn">{S["disclaimer"]}</div>
</div>

<div class="toc"><h2>{S["toc"]}</h2>{"".join(toc_rows)}</div>

{"".join(body)}
</body></html>"""


def html_to_pdf(html_text: str, out: Path, timeout: float = 120.0) -> None:
    """headless Chrome 打印成 PDF。

    Chrome 在 macOS 上写完 PDF 后进程不会自己退出（--print-to-pdf 只保证文件落盘），
    所以这里不能用 subprocess.run 干等 —— 轮询输出文件，尺寸稳定后主动收掉进程。
    """
    chrome = find_chrome()
    out = out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "report.html"
        src.write_text(html_text, encoding="utf-8")
        cmd = [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-background-networking",
            "--disable-sync",
            "--mute-audio",
            f"--user-data-dir={Path(tmp) / 'chrome'}",
            "--no-pdf-header-footer",
            "--virtual-time-budget=10000",
            f"--print-to-pdf={out}",
            src.as_uri(),
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        deadline, last_size, stable = time.time() + timeout, -1, 0
        while time.time() < deadline:
            if proc.poll() is not None:
                break
            size = out.stat().st_size if out.exists() else 0
            # 连续两次(≈1s)大小不变且非空 —— 认为写完了
            stable = stable + 1 if size > 0 and size == last_size else 0
            last_size = size
            if stable >= 2:
                break
            time.sleep(0.5)

        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(5)

        if not out.exists() or out.stat().st_size == 0:
            err = (proc.stderr.read() if proc.stderr else "")[-1500:]
            sys.exit(f"Chrome 导出 PDF 失败（exit {proc.returncode}）：\n{err}")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="把 TradingAgents 的 markdown 报告转成 PDF",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("path", nargs="?", help="报告目录（省略则自动找最新一次运行）")
    ap.add_argument("-o", "--output", help="输出 PDF 路径")
    ap.add_argument("--lang", choices=["zh", "en"], default="zh",
                    help="封面/目录/章节标题的语言（正文语言取决于报告本身）")
    ap.add_argument("--html-only", action="store_true", help="只生成 HTML，不调用 Chrome")
    args = ap.parse_args()

    root = resolve_root(Path(args.path).expanduser().resolve()) if args.path else latest_run()
    if not root.is_dir():
        sys.exit(f"不是目录：{root}")

    sections = collect(root)
    if not sections:
        sys.exit(
            f"{root} 下没找到可识别的报告文件。\n"
            f"预期是 reports/*.md（运行日志布局）或 1_analysts/ 等阶段目录（导出布局）。"
        )

    ticker, date = guess_meta(root)
    stamp = date or datetime.now().strftime("%Y%m%d")
    out = (
        Path(args.output).expanduser()
        if args.output
        else Path.cwd() / f"{ticker}_{stamp}_TradingAgents.pdf".replace("/", "-")
    )

    doc = build_html(root, sections, lang=args.lang)
    if args.html_only:
        out = out.with_suffix(".html")
        out.write_text(doc, encoding="utf-8")
    else:
        html_to_pdf(doc, out)

    S = STRINGS[args.lang]
    print(f"✓ {out}  ({out.stat().st_size / 1024:.0f} KB, {len(sections)} 个章节)")
    for stage, title, f in sections:
        label = f'{S["stages"].get(stage, stage)} / {S["sections"].get(title, title)}'
        print(f"    {label}  ←  {f.relative_to(root)}")


if __name__ == "__main__":
    main()
