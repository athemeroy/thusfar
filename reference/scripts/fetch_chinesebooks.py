"""Download a public-domain novel from chinesebooks.github.io into one TXT (chapter headings kept).

usage: python scripts/fetch_chinesebooks.py INDEX_URL OUT.txt
Only for public-domain works (e.g. authors who died more than 50 years ago).
"""
import html
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def get(url: str) -> str:
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (book-test-set)'})
            return urllib.request.urlopen(req, timeout=40).read().decode('utf-8', errors='replace')
        except Exception:
            time.sleep(3 * (attempt + 1))
    return ''


def main():
    index, out = sys.argv[1], sys.argv[2]
    s = get(index)
    base = re.escape(index.rstrip('/').replace('https://chinesebooks', 'https://ChineseBooks'))
    items = re.findall(r'href="(' + base + r'/(\d+)\.html)"[^>]*>(.*?)</a>', s, re.S | re.I)
    items = sorted({(int(i), u, html.unescape(re.sub('<[^>]+>', '', t)).strip().rstrip('>')) for u, i, t in items})
    print(len(items), 'chapters listed', flush=True)

    def one(item):
        _, url, title = item
        page = get(url)
        m = re.search(r'<div[^>]+id="articleContent"[^>]*>(.*?)<div[^>]+class="line"', page, re.S)
        body = m.group(1) if m else ''
        body = re.sub(r'<script.*?</script>', '', body, flags=re.S)
        body = re.sub(r'<br\s*/?>|</p>', '\n', body)
        text = html.unescape(re.sub(r'<[^>]+>', '', body))
        paras = [re.sub(r'[\s　]+', ' ', p).strip() for p in text.split('\n')]
        paras = [p for p in paras if p and '本章未完' not in p and 'ChineseBooks' not in p]
        return title.replace('○', '〇'), paras
    with ThreadPoolExecutor(4) as ex:
        chapters = list(ex.map(one, items))
    empty = [t for t, p in chapters if not p]
    lines = []
    for title, paras in chapters:
        lines.append(title)
        # the page repeats the chapter title as its first line
        if paras and paras[0].replace(' ', '') == title.replace(' ', '').replace('　', ''):
            paras = paras[1:]
        lines.extend(paras)
        lines.append('')
    text = '\n'.join(lines)
    open(out, 'w', encoding='utf-8').write(text)
    print(f'{len(chapters)} chapters, {len(text)} chars, empty: {len(empty)} {empty[:5]}')


if __name__ == '__main__':
    main()
