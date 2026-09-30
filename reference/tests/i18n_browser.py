"""Eight offline UI languages, preference persistence, and original book metadata."""
import argparse
import functools
import http.server
import json
import re
import threading
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--out-dir', default='/tmp/yedu-i18n-browser')
parser.add_argument('--locales', nargs='*', choices=['zh-CN', 'en', 'es', 'fr', 'de', 'pt-BR', 'ja', 'ko'])
args = parser.parse_args()
out = Path(args.out_dir)
out.mkdir(parents=True, exist_ok=True)
book_title = '清晨的书'
book_author = '作者甲'


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def data(self, value):
        raw = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == '/api/me':
            return self.data({'ok': True})
        if self.path == '/api/books':
            return self.data([{'id': 'book', 'title': book_title, 'author': book_author,
                               'len': 12000, 'added': 1, 'lang': 'zh', 'status': {'state': 'idle'}}])
        if self.path == '/api/settings':
            return self.data({'base_url': 'https://example.test/v1', 'model': 'fixture',
                              'api_key_set': True, 'api_key_last4': '1234'})
        if self.path.startswith('/api/'):
            self.send_error(404)
            return
        return super().do_GET()

    def do_PUT(self):
        if self.path == '/api/settings':
            raw = json.dumps({'error': '模型接口地址无效'}, ensure_ascii=False).encode()
            self.send_response(400)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        self.send_error(404)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(ROOT / 'web')))
threading.Thread(target=server.serve_forever, daemon=True).start()
origin = f'http://127.0.0.1:{server.server_address[1]}'
locales = args.locales or ['zh-CN', 'en', 'es', 'fr', 'de', 'pt-BR', 'ja', 'ko']
checks = []
errors = []
offline_ok = False
try:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True, args=['--no-proxy-server'])
        for code in locales:
            context = browser.new_context(locale=code, viewport={'width': 390, 'height': 844},
                                          service_workers='block', user_agent='Mozilla/5.0 YeduApp/1.7.0 YeduStandalone/1')
            context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page = context.new_page()
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.goto(origin, wait_until='networkidle')
            page.locator('.library-card').first.wait_for()
            assert page.locator('html').get_attribute('lang') == code
            assert page.title() == ('页读' if code == 'zh-CN' else 'Thusfar')
            assert page.locator('.library-card').get_by_text(book_title, exact=True).count() >= 1
            assert page.locator('.library-card').get_by_text(book_author, exact=True).count() >= 1
            assert page.locator('html').evaluate('(el) => el.scrollWidth <= innerWidth'), f'{code}: shelf overflow'
            import_button = page.locator('.library-import-button').bounding_box()
            assert import_button and import_button['x'] + import_button['width'] <= 390, f'{code}: import button clipped'
            if code != 'zh-CN':
                for button in page.locator('.library-filters button').all():
                    box = button.bounding_box()
                    assert box and box['x'] >= 0 and box['x'] + box['width'] <= 390, f'{code}: filter hidden'
            if code in ('en', 'es', 'ja', 'ko'):
                page.screenshot(path=str(out / f'shelf-{code}.png'), full_page=True)
            page.locator('.library-settings-button').click()
            page.locator('.language-settings select').wait_for()
            assert page.locator('.language-settings select option').count() == 9
            assert page.locator('.language-settings select').input_value() == 'auto'
            assert page.locator('html').evaluate('(el) => el.scrollWidth <= innerWidth'), f'{code}: settings overflow'
            page.set_viewport_size({'width': 320, 'height': 720})
            assert page.locator('html').evaluate('(el) => el.scrollWidth <= innerWidth'), f'{code}: 320px overflow'
            page.set_viewport_size({'width': 390, 'height': 844})
            if code in ('en', 'es', 'fr', 'de', 'pt-BR'):
                assert not re.search(r'[\u3400-\u9fff]', page.locator('.model-settings header').inner_text()), f'{code}: untranslated header'
            if code in ('ja', 'ko'):
                assert page.locator('.model-settings h1').inner_text() != '模型设置'
            error_text = page.evaluate("""async () => {
                const {api} = await import('/js/api.js');
                try { await api.saveSettings({base_url:'invalid',model:'fixture'}); return ''; }
                catch (error) { return error.message; }
            }""")
            assert error_text and (code not in ('en', 'es', 'fr', 'de', 'pt-BR') or not re.search(r'[\u3400-\u9fff]', error_text)), f'{code}: server error untranslated'
            if code != 'zh-CN':
                assert error_text != '模型接口地址无效'
            if code in ('en', 'es', 'ja', 'ko'):
                page.screenshot(path=str(out / f'settings-{code}.png'), full_page=True)
            # A manual choice wins over the browser language and survives reloading.
            page.locator('.language-settings select').select_option('en' if code == 'zh-CN' else 'zh-CN')
            page.locator('.language-settings select').wait_for()
            chosen = 'en' if code == 'zh-CN' else 'zh-CN'
            assert page.locator('html').get_attribute('lang') == chosen
            assert page.locator('.language-settings select').input_value() == chosen
            page.reload(wait_until='networkidle')
            assert page.locator('html').get_attribute('lang') == chosen
            checks.append(code)
            context.close()
        offline_context = browser.new_context(locale='ja', viewport={'width': 390, 'height': 844})
        offline_context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
        offline_page = offline_context.new_page()
        offline_page.goto(origin, wait_until='networkidle')
        offline_page.evaluate('navigator.serviceWorker.ready')
        offline_page.wait_for_function('!!navigator.serviceWorker.controller')
        offline_context.set_offline(True)
        cached_locales = offline_page.evaluate("""async () => {
            const codes = ['en','es','fr','de','pt-BR','ja','ko'];
            return await Promise.all(codes.map(async code => {
                const response = await fetch(`/js/locales/${code}.js`);
                return response.status === 200 && (await response.text()).startsWith('export default {');
            }));
        }""")
        assert all(cached_locales), 'offline language catalog missing from service-worker shell'
        offline_ok = True
        offline_context.close()
        assert not errors, errors
        browser.close()
finally:
    server.shutdown()
(out / 'acceptance.json').write_text(json.dumps({'locales': checks, 'offline_catalogs': offline_ok, 'errors': errors}, ensure_ascii=False, indent=2))
print(json.dumps({'locales': checks, 'offline_catalogs': offline_ok, 'errors': errors}, ensure_ascii=False))
