"""Synthetic browser acceptance. No real books, server imports, models, or external API calls."""
import argparse
import functools
import http.server
import json
import re
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / 'web'
blocks, at = [], 0
for n in range(35):
    text = (f'这是第{n + 1}段原创测试文本。人物甲看见清晨的窗户，随后继续阅读。这里只包含测试夹具，没有真实书籍内容。' * 4)
    blocks.append({'k': 'p', 't': text, 'o': at})
    at += len(text) + 2
CHAPTER = {'title': '测试章节', 'depth': 0, 'parent': '', 'o0': 0, 'o1': at, 'kind': 'body', 'spoil': False}
BASE_BOOK = {'id': 'fixture', 'title': '测试用书', 'author': 'Test', 'len': at, 'lang': 'zh', 'genre': 'novel', 'version': 'fixture-v1',
             'chapters': [CHAPTER], 'status': {'state': 'done', 'frontier': at, 'people': 0}, 'progress': {'pos': 2000, 'pct': 0, 't': 1}}


class Fixture(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_body(self, body, content_type='application/json', status=200):
        if not isinstance(body, bytes):
            body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def data(self, value, status=200):
        self.send_body(json.dumps(value, ensure_ascii=False), status=status)

    def book(self):
        status = {**BASE_BOOK['status']}
        if self.server.quality_pending:
            status['quality'] = {'state': 'pending', 'pending': ['internal-fixture-reason']}
        return {**BASE_BOOK, 'status': status, 'progress': self.server.progress.copy()}

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == '/api/books':
            return self.data([self.book()])
        if u.path == '/api/books/slow':
            time.sleep(.7)
            return self.data({**self.book(), 'id': 'slow'})
        if u.path == '/api/books/fixture':
            return self.data(self.book())
        if u.path == '/api/books/fixture/chapters/0':
            return self.data({**CHAPTER, 'n': 0, 'blocks': blocks, 'mentions': [], 'notes': {}})
        if u.path == '/api/books/fixture/kg':
            q = parse_qs(u.query)
            lo, hi = int(q.get('from', [-1])[0]), int(q.get('to', [0])[0])
            records = [{'t': 'person', 'p': 10, 'id': 'P1', 'name': '甲'}, {'t': 'person', 'p': 6000, 'id': 'P2', 'name': 'FUTURE_PERSON'}]
            return self.data({'from': lo, 'to': hi, 'frontier': at,
                              'records': [r for r in records if lo < r['p'] <= hi], 'before': sum(r['p'] <= lo for r in records), 'state': 'done'})
        if u.path == '/api/books/fixture/offline-manifest':
            return self.data({'version': 'fixture-v1', 'book': self.book(), 'chapters': [{'n': 0, 'url': '/api/books/fixture/chapters/0', 'images': ['/api/books/fixture/img/test.svg']}],
                              'assets': ['/api/books/fixture/img/cover.svg'], 'graph': {'url': f'/api/books/fixture/kg?from=-1&to={at}', 'to': at}, 'frontier': at, 'state': 'done'})
        if u.path in ('/api/books/fixture/img/test.svg', '/api/books/fixture/img/cover.svg'):
            return self.send_body('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>', 'image/svg+xml')
        if u.path.startswith('/api/'):
            return self.data({'error': 'Unknown fixture endpoint'}, 404)
        if u.path == '/sw.js':
            source = (WEB / 'sw.js').read_text()
            if self.server.upgrade:
                source = re.sub(r"const SHELL = '[^']+';", "const SHELL = 'yedu-shell-browser-test-next';", source, count=1)
            return self.send_body(source, 'text/javascript')
        return super().do_GET()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/api/books/fixture/ask':
            self.server.asks.append(body)
            if body.get('q') == 'delay':
                time.sleep(.7)
            return self.send_body('event: answer\ndata: ' + json.dumps({'text': 'FUTURE_ONLY_ANSWER', 'cites': [], 'guard': {'verdict': 'ok'}}) + '\n\n', 'text/event-stream')
        if self.path == '/api/books/fixture/process':
            self.server.process_calls += 1
        return self.data({'ok': True})

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path.endswith('/progress'):
            if 'expected_t' in body and body['expected_t'] != self.server.progress['t']:
                return self.data({'error': '进度冲突', 'progress': self.server.progress}, 409)
            cutoff = body.get('cutoff', body['pos'])
            assert body['pos'] <= cutoff <= at
            self.server.progress = {'pos': body['pos'], 'cutoff': cutoff, 'pct': cutoff / at * 100, 't': time.time()}
            return self.data({'ok': True, 'progress': self.server.progress})
        return self.data({'ok': True})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out-dir', default='/tmp/yedu-frontend-browser')
    parser.add_argument('--progress-only', action='store_true')
    args = parser.parse_args()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Fixture, directory=str(WEB)))
    server.progress = BASE_BOOK['progress'].copy()
    server.asks = []
    server.upgrade = False
    server.quality_pending = False
    server.process_calls = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_address[1]}'
    result = {'isolation': 'temporary loopback fixture server, synthetic book/API responses only', 'checks': [], 'page_errors': []}
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=['--no-proxy-server'])
            context = browser.new_context(locale='zh-CN',viewport={'width': 390, 'height': 844})
            context.add_init_script("localStorage.setItem('tip-shown', '1')")
            context.add_init_script("window.__intervals=new Set(); const si=window.setInterval.bind(window),ci=window.clearInterval.bind(window); window.setInterval=(...a)=>{const id=si(...a);__intervals.add(id);return id}; window.clearInterval=id=>{__intervals.delete(id);ci(id)}")
            context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page = context.new_page()
            page.set_default_timeout(20000)
            page.on('pageerror', lambda e: result['page_errors'].append(str(e)))

            def open_pane(label):
                if page.locator('.sheet.open').count():
                    page.locator('.sheet .pane-nav .icon-btn').click()
                page.evaluate("document.querySelector('.reader').classList.add('ui')")
                page.locator('.dock button', has_text=label).click()

            page.goto(origin + '/#/read/fixture', wait_until='networkidle')
            page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length > 0")
            first = int(page.locator('.folio').inner_text().split()[0])
            assert first > 2
            # A right-edge tap must turn the page even if its text would match
            # the implicit pronoun lookup. Otherwise the lookup eats every tap.
            page.evaluate("""() => {
              const p = document.querySelector('.flow p[data-o]');
              const node = document.createTextNode('他'); p.append(node);
              const original = document.caretRangeFromPoint?.bind(document);
              window.__restoreCaretProbe = () => { node.remove(); document.caretRangeFromPoint = original; };
              window.__caretProbeCalls = 0;
              document.caretRangeFromPoint = () => {
                window.__caretProbeCalls++;
                const r = document.createRange(); r.setStart(node, 0); r.collapse(true); return r;
              };
              document.querySelector('.reader').classList.remove('ui');
            }""")
            box = page.locator('.stage').bounding_box()
            page.mouse.click(box['x'] + box['width'] - 12, box['y'] + box['height'] * .52)
            page.wait_for_function("n => Number(document.querySelector('.folio').firstChild.textContent) > n", arg=first)
            assert page.evaluate('window.__caretProbeCalls') == 0
            page.evaluate('window.__restoreCaretProbe()')
            page.keyboard.press('PageUp')
            page.wait_for_function("n => Number(document.querySelector('.folio').firstChild.textContent) === n", arg=first)
            result['checks'].append('edge page turn wins over an implicit pronoun lookup')
            if args.progress_only:
                total = int(page.locator('.folio').inner_text().split()[-1])
                open_pane('目录')
                page.locator('.sheet .jump input').fill(str(total))
                page.locator('.sheet .jump button').click()
                page.wait_for_function("n => Number(document.querySelector('.folio').firstChild.textContent) === n", arg=total)
                page.wait_for_function("!JSON.parse(localStorage.getItem('resume:fixture')).dirty")
                local = page.evaluate("JSON.parse(localStorage.getItem('resume:fixture'))")
                assert local['pos'] < at and local['cutoff'] == at and local['pct'] == 100
                assert server.progress['pos'] == local['pos'] and server.progress['pct'] == 100
                result['checks'].append('final page is 100 percent while resume remains at its start anchor')
                assert not result['page_errors']
                browser.close()
                print(json.dumps(result, ensure_ascii=False, indent=2))
                return
            open_pane('问书')
            page.locator('.sheet .ask-bar textarea').fill('first')
            page.locator('.sheet .ask-bar button').click()
            page.locator('.sheet .msg.ai').wait_for()
            original_cutoff = server.asks[-1]['pos']
            page.evaluate('document.activeElement.blur()')
            page.keyboard.press('PageUp')
            page.keyboard.press('PageUp')
            page.wait_for_function("n => Number(document.querySelector('.folio').firstChild.textContent) < n", arg=first)
            page.wait_for_function("document.querySelector('.sheet .ask-bar textarea') && !document.querySelector('.sheet .msg.ai')")
            page.locator('.sheet .ask-bar textarea').fill('after-rewind')
            page.locator('.sheet .ask-bar button').click()
            page.locator('.sheet .msg.ai').wait_for()
            assert server.asks[-1]['pos'] < original_cutoff
            assert page.locator('.sheet .msg.ai').count() == 1
            result['checks'].append('rewind removes future answers and submits the current cutoff')

            page.locator('.sheet .ask-bar textarea').fill('delay')
            page.locator('.sheet .ask-bar button').click()
            assert page.locator('.sheet .ask-bar button').is_disabled()
            page.evaluate('document.activeElement.blur()')
            page.keyboard.press('PageUp')
            page.wait_for_timeout(1000)
            assert page.locator('.sheet .msg.ai').count() == 0
            result['checks'].append('one request in flight; rewind cancels and drops late answer')

            await_ready = "navigator.serviceWorker.ready.then(() => navigator.serviceWorker.controller ? true : new Promise(r => navigator.serviceWorker.addEventListener('controllerchange', () => r(true), {once:true})))"
            page.evaluate(await_ready)
            open_pane('资料')
            page.get_by_role('button', name='管理本书 · 离线与整理', exact=True).click()
            page.get_by_role('button', name='离线下载本书', exact=True).click()
            page.get_by_role('button', name='已离线下载 · 正文、插图和现有资料', exact=True).wait_for()
            cache_before = page.evaluate('caches.keys()')
            assert any(k.startswith('yedu-book-fixture@') for k in cache_before)
            result['checks'].append('manifest download includes chapter, image, graph and publishes completion')
            page.locator('.sheet .pane-nav .icon-btn').click()
            context.set_offline(True)
            page.evaluate('document.activeElement.blur()')
            page.keyboard.press('PageDown')
            local = page.evaluate("JSON.parse(localStorage.getItem('resume:fixture'))")
            assert local['dirty']
            page.reload(wait_until='domcontentloaded')
            page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length > 0")
            resumed = page.evaluate("JSON.parse(localStorage.getItem('resume:fixture')).pos")
            assert resumed == local['pos'], (resumed, local)
            coverage = page.evaluate("fetch('/api/books/fixture/kg?from=100&to=500').then(r=>r.json())")
            assert coverage['from'] == 100 and coverage['to'] == 500 and coverage['records'] == []
            assert page.evaluate("fetch('/api/books/fixture/img/cover.svg').then(r=>r.ok)")
            result['checks'].append('offline reload preserves exact local resume anchor')
            result['checks'].append('offline graph slices exact ranges and cover-only assets remain available')
            page.goto(origin + '/', wait_until='domcontentloaded')
            page.locator('.book-card').wait_for()
            assert '测试用书' in page.locator('.book-card').inner_text()
            result['checks'].append('offline installed-app start URL opens cached shelf')

            context.set_offline(False)
            server.upgrade = True
            page.evaluate("navigator.serviceWorker.getRegistration().then(reg => new Promise(async (resolve, reject) => { const t=setTimeout(()=>reject(Error('worker update timeout')),15000); navigator.serviceWorker.addEventListener('controllerchange',()=>{clearTimeout(t);resolve(true)},{once:true}); await reg.update(); }))")
            cache_after = page.evaluate('caches.keys()')
            assert all(k in cache_after for k in cache_before if k.startswith('yedu-book-fixture@'))
            context.set_offline(True)
            page.reload(wait_until='domcontentloaded')
            page.locator('.book-card').wait_for()
            page.locator('.book-card .book-open').click()
            page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length > 0")
            result['checks'].append('worker upgrade preserves offline downloaded book and reopen')
            page.screenshot(path=str(out / 'offline-reader.png'))

            context.set_offline(False)
            # Network-first metadata is cancelled when a newer route takes ownership.
            page.evaluate("location.hash='#/read/slow'")
            page.wait_for_timeout(80)
            page.evaluate("location.hash='#/'")
            page.locator('.book-card').wait_for()
            page.wait_for_timeout(900)
            assert page.locator('.reader').count() == 0
            result['checks'].append('late book route cannot overwrite a newer shelf route')
            page.set_viewport_size({'width': 1440, 'height': 900})
            page.locator('.book-card .book-open').click()
            page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length > 0")
            page.screenshot(path=str(out / 'desktop-reader.png'))
            # A second device's update must be acknowledged before replacing its anchor.
            server.progress = {'pos': 100, 'pct': 1, 't': time.time() + 100}
            page.evaluate('document.activeElement.blur()')
            page.keyboard.press('PageDown')
            page.get_by_role('button', name='保留本机位置', exact=True).wait_for()
            page.get_by_role('button', name='保留本机位置', exact=True).click()
            page.wait_for_function("!JSON.parse(localStorage.getItem('resume:fixture')).dirty")
            assert server.progress['pos'] == page.evaluate("JSON.parse(localStorage.getItem('resume:fixture')).pos")
            result['checks'].append('progress conflict is visible and explicit local choice synchronizes safely')
            page.locator('.margin button', has_text='关系图').click()
            page.locator('.margin .play').click()
            assert page.evaluate('__intervals.size') >= 2
            page.evaluate("location.hash='#/'")
            page.locator('.book-card').wait_for()
            assert page.evaluate('__intervals.size') == 0
            result['checks'].append('leaving graph replay clears graph and reader timers')
            server.quality_pending = True
            page.reload(wait_until='networkidle')
            page.get_by_role('button', name='《测试用书》书籍菜单', exact=True).click()
            page.get_by_role('button', name='重试待核对资料', exact=True).wait_for()
            assert '待核对' in page.locator('dialog[open]').inner_text()
            assert 'internal-fixture-reason' not in page.locator('dialog[open]').inner_text()
            assert server.process_calls == 0
            page.once('dialog', lambda d: d.dismiss())
            page.get_by_role('button', name='重试待核对资料', exact=True).click()
            assert server.process_calls == 0
            page.once('dialog', lambda d: d.accept())
            page.get_by_role('button', name='重试待核对资料', exact=True).click()
            page.wait_for_timeout(150)
            assert server.process_calls == 1
            result['checks'].append('done-but-pending quality is visible; retry requires explicit cost confirmation')
            assert not result['page_errors'], result['page_errors']
            result['checks'].append('phone and desktop reader boot with zero page errors')
            browser.close()
    finally:
        server.shutdown()
        server.server_close()
        (out / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
