"""Fetch a public-domain book to try the reader on.

    python3 scripts/sample_books.py                 # list what is on offer
    python3 scripts/sample_books.py jekyll          # download one into data/samples/
    python3 scripts/sample_books.py --all

Books are not shipped in the repository: they are megabytes of someone else's writing, and which
ones are in the public domain depends on where you are. These are sources that state their own
licence — Project Gutenberg, 维基文库, 青空文庫 — and the list spans the kinds of book the pipeline
is meant to cope with, so it doubles as a smoke test: a Chinese novel, an English one, a play, a
Japanese one, and a work of non-fiction.

Never point this at a piracy site. A serialised web novel someone uploaded is not public domain.
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

BOOKS = {
    'jekyll': ('化身博士 / The Strange Case of Dr. Jekyll and Mr. Hyde', 'en', '英文小说 · 约 14 万字符',
               'https://www.gutenberg.org/files/43/43-0.txt'),
    'sherlock': ('福尔摩斯探案集 / The Adventures of Sherlock Holmes', 'en', '英文短篇集 · 每篇独立',
                 'https://www.gutenberg.org/files/1661/1661-0.txt'),
    'hamlet': ('哈姆雷特 / Hamlet', 'en', '英文剧本 · 幕与场',
               'https://www.gutenberg.org/files/1524/1524-0.txt'),
    'origin': ('物种起源 / On the Origin of Species', 'en', '英文非虚构 · 概念卡而非人物卡',
               'https://www.gutenberg.org/files/1228/1228-0.txt'),
    'kokoro': ('こころ（夏目漱石）', 'ja', '日文小说 · ruby 注音',
               'https://www.aozora.gr.jp/cards/000148/files/773_ruby_5968.zip'),
}
UA = {'User-Agent': 'yedu-sample-fetcher (a spoiler-free reader; one file, by hand)'}


def fetch(key: str, out: Path) -> Path | None:
    title, lang, note, url = BOOKS[key]
    dest = out / f'{key}.txt'
    if dest.exists():
        print(f'  {key}: 已经有了 → {dest}')
        return dest
    print(f'  {key}: 下载 {title} …', flush=True)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
            raw = r.read()
    except Exception as e:
        print(f'    失败：{type(e).__name__}: {e}')
        print(f'    手动下载：{url}')
        return None
    if url.endswith('.zip'):            # 青空文庫 ships zipped Shift-JIS
        import io
        import zipfile
        with zipfile.ZipFile(io.BytesIO(raw)) as z:
            name = next((n for n in z.namelist() if n.lower().endswith('.txt')), None)
            if not name:
                print('    压缩包里没有 txt')
                return None
            raw = z.read(name)
    for enc in ('utf-8', 'shift_jis', 'gb18030', 'latin-1'):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        print('    认不出编码')
        return None
    dest.write_text(text, encoding='utf-8')
    print(f'    {len(text):,} 字符 → {dest}')
    return dest


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('which', nargs='*', help='which books (default: list them)')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--out', type=Path, default=Path('data/samples'))
    a = ap.parse_args()

    names = list(BOOKS) if a.all else a.which
    if not names:
        print('公版样书（都注明了自己的授权）：\n')
        for k, (title, lang, note, url) in BOOKS.items():
            print(f'  {k:10s} {title}\n             {note}\n             {re.sub("^https?://", "", url)[:60]}')
        print('\n  python3 scripts/sample_books.py jekyll        下载一本')
        print('  python3 scripts/sample_books.py --all         全部')
        print('\n下载后在书架上传它，或者直接跑：')
        print('  python3 -m server.app     然后把 data/samples/*.txt 拖进去')
        return 0

    a.out.mkdir(parents=True, exist_ok=True)
    unknown = [n for n in names if n not in BOOKS]
    if unknown:
        print(f'不认识：{", ".join(unknown)}；可选 {", ".join(BOOKS)}')
        return 1
    got = [p for n in names if (p := fetch(n, a.out))]
    print(f'\n{len(got)}/{len(names)} 本就位。上传它们，书架上会显示预计耗时和费用，按下按钮才开始花钱。')
    return 0 if len(got) == len(names) else 1


if __name__ == '__main__':
    raise SystemExit(main())
