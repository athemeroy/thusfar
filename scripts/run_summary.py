"""One line per processed book: time, people, model usage and cost.

usage: python3 scripts/run_summary.py data/books/<id> ...
Prices (CNY per million tokens, input/output) come from pipeline/models.py.
DeepSeek official: deepseek-flash ¥2/¥8 (peak), ¥1/¥4 off-peak.
"""
import json
import re
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.models import PRICES, cost_of  # noqa: E402


def main():
    print('| 书 | 段 | 耗时 | 人物 | 模型调用（入/出 token） | 费用 | JEV 次数 |\n|---|---|---|---|---|---|---|')
    for d in map(Path, sys.argv[1:]):
        st = json.loads((d / 'status.json').read_text())
        log = (d / 'work' / 'run.log').read_text().splitlines()
        times = [datetime.strptime(l[:8], '%H:%M:%S') for l in log if re.match(r'\d\d:\d\d:\d\d ', l)]
        mins = (times[-1] - times[0]).seconds / 60 if len(times) > 1 else 0
        u = st.get('usage') or {}
        parts = [f"{m.split('+')[0]} {x['calls']} 次 {x['prompt'] / 1e6:.2f}M/{x['completion'] / 1e6:.2f}M"
                 for m, x in (u.get('by_model') or {}).items()]
        lo, hi = cost_of(u)
        extra = ''
        for m, x in (u.get('by_model') or {}).items():
            off_price = (PRICES.get(m.split('+')[0]) or {}).get('official')
            if off_price:
                off = (x['prompt'] * off_price[0] + x['completion'] * off_price[1]) / 1e6
                extra = f'（官方闲时价 ¥{off:.2f}，高峰 ¥{off * 2:.2f}）'
        cost = f'¥{lo:.2f}' if abs(hi - lo) < 0.005 else f'¥{lo:.2f}～{hi:.2f}'
        print(f"| {d.name} | {st['done']}/{st['total']} | {mins:.0f} 分钟 | {st.get('people')} | {'；'.join(parts)} | {cost}{extra} | {u.get('jev_calls', 0)} |")


if __name__ == '__main__':
    main()
