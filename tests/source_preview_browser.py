"""Isolated preview journeys: no real books, application writes, models or remote network."""
import argparse
import functools
import http.server
import json
from pathlib import Path
import threading

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]


class Fixture(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/preview-fixture':
            body = b'<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/css/app.css"><link rel="stylesheet" href="/css/source-preview.css"><body></body>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()


SETUP = r"""async () => {
  const {sourcePreviewView} = await import('/js/source-preview.js');
  const {api} = await import('/js/api.js');
  window.make = async (options = {}) => {
    window.fixture?.leave?.();
    document.body.replaceChildren();
    const title = document.createElement('div'), pane = document.createElement('div'), nav = document.createElement('div');
    title.className = 't'; nav.className = 'pane-nav'; pane.className = 'pane';
    nav.append(title); pane.append(nav); document.body.append(pane);
    pane.style.maxWidth = '480px'; pane.style.padding = '20px';
    const text = '前文。😀这是原文。<img src=x onerror=alert(1)>。FUTURE_SENTINEL';
    const safe = text.indexOf('FUTURE_SENTINEL');
    const chapter = {o0: 0, o1: text.length, blocks: [{o: 0, k: 'p', t: text}]};
    const book = {id: 'fixture', len: text.length, version: 'v1', chapters: [{o0: 0, o1: text.length}]};
    const model = {book, generation: 'v1', info: {cutoff: options.cutoff ?? safe}};
    const fixture = {calls: 0, jumps: [], back: 0, closed: 0, aborted: false, model, safe, text, pane, title};
    window.fixture = fixture;
    api.chapter = async (_id, _n, options) => {
      fixture.calls++;
      options.signal.addEventListener('abort', () => {fixture.aborted = true;});
      if (fixture.mode === 'failure') throw new Error('测试连接断开');
      if (fixture.mode === 'delay') return new Promise(resolve => {fixture.resolve = () => resolve(chapter);});
      return chapter;
    };
    fixture.mode = options.mode;
    const ctx = {...model, current: () => model,
      onLeave: fn => {fixture.leave = fn;},
      chapterTitle: () => options.futureTitle ? 'FUTURE_TITLE' : '当前章节',
      jumpSource: async (s,e) => {fixture.jumps.push([s,e]);},
      panes: {stack: Array.from({length: options.nested ? 2 : 1}, () => ({})),
        back: () => {fixture.back++;}, close: () => {fixture.closed++;}, render: () => {fixture.refreshed = true;}},
    };
    sourcePreviewView(ctx, {start: options.start ?? 3, end: options.end ?? 9}, pane, title);
    await new Promise(resolve => setTimeout(resolve, 0));
  };
}"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out-dir', default='/tmp/yedu-source-preview-browser')
    args = parser.parse_args()
    out = Path(args.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    handler = functools.partial(Fixture, directory=str(ROOT / 'web'))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    checks, errors = [], []
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page(locale='zh-CN', viewport={'width': 390, 'height': 844})
            page.on('pageerror', lambda e: errors.append(str(e)))
            origin = f'http://127.0.0.1:{server.server_port}'
            page.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page.goto(origin + '/preview-fixture')
            page.evaluate(SETUP)

            page.evaluate('make()')
            assert page.locator('mark').inner_text() == '😀这是原文'
            assert 'FUTURE_SENTINEL' not in page.locator('body').inner_text()
            assert page.locator('.source-preview-content img').count() == 0
            assert '<img src=x onerror=alert(1)>' in page.locator('.source-preview-content').inner_text()
            assert page.evaluate('fixture.calls === 1 && fixture.jumps.length === 0')
            page.screenshot(path=str(out / 'preview-mobile.png'), full_page=True)
            page.get_by_role('button', name='转到这里阅读', exact=True).click()
            assert page.evaluate('JSON.stringify(fixture.jumps)') == '[[3,9]]'
            checks.append('safe UTF-16 quote, plain-text rendering, bounded context and explicit commit')

            page.evaluate('make({start: 40, end: 48, cutoff: 10, futureTitle: true})')
            assert page.evaluate('fixture.calls === 0 && fixture.jumps.length === 0')
            assert 'FUTURE_TITLE' not in page.locator('body').inner_text()
            assert 'FUTURE_SENTINEL' not in page.locator('body').inner_text()
            page.get_by_role('button', name='转到这里阅读（后文）', exact=True).click()
            assert page.evaluate('JSON.stringify(fixture.jumps)') == '[[40,48]]'
            checks.append('future-only preview fetches nothing and reveals no title before explicit jump')

            page.evaluate('make({start: 3, end: 48, cutoff: 10, futureTitle: true})')
            assert 'FUTURE_TITLE' not in page.locator('body').inner_text()
            assert '<img' not in page.locator('.source-preview-content').inner_text()
            assert '后文保持隐藏' in page.locator('body').inner_text()
            checks.append('partial future quote and title are cut off before rendering')

            page.evaluate('make({mode: "failure"})')
            assert '测试连接断开' in page.locator('body').inner_text()
            page.evaluate('fixture.mode = null')
            page.get_by_role('button', name='重新获取原文').click()
            page.wait_for_function('document.querySelector("mark")')
            assert page.evaluate('fixture.calls === 2 && fixture.jumps.length === 0')
            checks.append('failed source fetch can retry without a reading-position write')

            page.evaluate('make({mode: "delay"})')
            page.evaluate('fixture.model.info = {cutoff: 2}; fixture.resolve()')
            page.wait_for_function('document.body.textContent.includes("阅读位置已改变")')
            assert page.locator('mark').count() == 0
            assert '😀这是原文' not in page.locator('body').inner_text()
            checks.append('late response after rewind cannot disclose old scope')

            page.evaluate('make({mode: "delay"})')
            page.evaluate('fixture.model.generation = "v2"; fixture.resolve()')
            page.wait_for_function('document.body.textContent.includes("文本版本已改变")')
            assert page.locator('mark').count() == 0
            assert page.get_by_role('button', name='按当前页重新查看').count() == 0
            checks.append('late response from a different source generation is rejected')

            page.evaluate('make({mode: "delay"})')
            page.evaluate('fixture.leave(); fixture.pane.textContent = "NEW_PANE"; fixture.resolve()')
            page.wait_for_timeout(20)
            assert page.evaluate('fixture.aborted && fixture.pane.textContent === "NEW_PANE"')
            checks.append('pane leave aborts its request and rejects late DOM writes')

            page.evaluate('make({nested: true})')
            page.get_by_role('button', name='返回上一项').click()
            assert page.evaluate('fixture.back === 1 && fixture.closed === 0 && fixture.jumps.length === 0')
            page.evaluate('make()')
            page.get_by_role('button', name='返回阅读', exact=True).click()
            assert page.evaluate('fixture.closed === 1 && fixture.jumps.length === 0')
            checks.append('back respects pane stack without changing reading position')
            assert not errors, errors
            browser.close()
    finally:
        server.shutdown()
        server.server_close()
    receipt = {'ok': True, 'checks': checks, 'page_errors': errors, 'no_models_or_real_books': True}
    (out / 'validation.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == '__main__':
    main()
