"""Offline package journeys through the real worker, using only disposable local fixtures."""
import argparse
import functools
import http.server
import importlib.util
import json
from pathlib import Path
import threading
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('offline_base_fixture', ROOT / 'tests/frontend_browser.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class Fixture(base.Fixture):
    def do_GET(self):
        path = urlparse(self.path).path
        if self.server.api_unavailable and path.startswith('/api/'):
            return self.data({'error': 'fixture API unavailable'}, status=503)
        if path == '/api/books/fixture/offline-manifest':
            self.server.manifest_calls += 1
            return self.data({'version': self.server.version, 'book': self.book(),
                              'chapters': [{'n': 0, 'url': '/api/books/fixture/chapters/0', 'images': ['/api/books/fixture/img/test.svg']}],
                              'assets': ['/api/books/fixture/img/cover.svg'],
                              'notebook': {'url': '/api/books/fixture/notebook'},
                              'graph': {'url': f'/api/books/fixture/kg?from=-1&to={base.at}', 'to': base.at},
                              'frontier': base.at, 'state': 'done'})
        if path == '/api/books/fixture/notebook':
            return self.data({'items': [{'id': 'personal', 'revision': 3, 'text': '下载时保留的个人摘记'}]})
        if path == '/api/books/fixture/kg' and self.server.fail_graph:
            return self.data({'error': '模拟更新中断'}, status=503)
        if path == '/api/books/fixture/chapters/0':
            self.server.chapter_calls += 1
            if self.server.slow:
                time.sleep(.7)
        return super().do_GET()

    def do_POST(self):
        self.server.writes += 1
        return self.data({'error': 'fixture forbids application writes'}, status=409)

    do_PUT = do_POST
    do_DELETE = do_POST


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out-dir', default='/tmp/yedu-offline-library-browser')
    args = parser.parse_args()
    out = Path(args.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Fixture, directory=str(ROOT / 'web')))
    server.quality_pending = False
    server.progress = dict(base.BASE_BOOK['progress'])
    server.asks = []
    server.process_calls = 0
    server.upgrade = False
    server.version = 'package-v1'
    server.fail_graph = False
    server.slow = False
    server.api_unavailable = False
    server.manifest_calls = server.chapter_calls = server.writes = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    result = {'checks': [], 'page_errors': []}
    step = 'boot'
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context(locale='zh-CN',viewport={'width': 390, 'height': 844})
            origin = f'http://127.0.0.1:{server.server_port}'
            context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page = context.new_page()
            page.set_default_timeout(20000)
            page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
            original_wait = page.wait_for_function
            def wait_condition(expression, **kwargs):
                try:
                    return original_wait(expression, **kwargs)
                except Exception:
                    result['failure_body'] = page.locator('body').inner_text()
                    page.screenshot(path=str(out / 'failure.png'), full_page=True)
                    raise
            page.wait_for_function = wait_condition
            page.goto(origin + '/#/offline', wait_until='domcontentloaded')
            page.wait_for_function('!!navigator.serviceWorker.controller')
            page.get_by_role('heading', name='本机书包').wait_for()
            page.get_by_role('button', name='选择书籍下载', exact=True).first.click()
            card = page.locator('.offline-book[data-book-id="fixture"]')
            card.get_by_role('button', name='下载到本机', exact=True).wait_for()
            assert server.manifest_calls == 0, 'opening the center must not silently check every server manifest'

            step = 'download'
            card.get_by_role('button', name='下载到本机', exact=True).click()
            page.wait_for_function('document.querySelector(".offline-book-state")?.textContent === "可离线阅读"')
            assert server.manifest_calls == 2
            assert card.get_by_role('link', name='打开阅读').is_visible()
            result['checks'].append('explicit full download publishes verified offline package and reading action')

            step = 'verified freshness'
            card.get_by_role('button', name='检查更新').click()
            page.wait_for_function('document.querySelector(".offline-book-check")?.textContent.includes("书房内容一致")')
            server.version = 'package-v2'
            card.get_by_role('button', name='检查更新').click()
            page.wait_for_function('document.querySelector(".offline-book-check")?.textContent.includes("有新内容")')
            result['checks'].append('freshness follows an explicit manifest check, not source book.version')

            step = 'failed update'
            server.fail_graph = True
            card.get_by_role('button', name='更新本机副本').click()
            page.wait_for_function('document.querySelector(".offline-book-message")?.textContent.includes("503")')
            inventory = page.evaluate("async()=>{const {offlineWorkerRequest}=await import('/js/offline-library.js');return offlineWorkerRequest('offline-inventory')}")
            assert inventory['packages'][0]['version'] == 'package-v1'
            assert inventory['packages'][0]['available'] is True
            assert inventory['packages'][0]['partial'] is True
            result['checks'].append('failed update preserves the published readable snapshot and resumable partial download')
            server.fail_graph = False

            step = 'cancel and removal exclusion'
            server.version = 'package-v3'
            server.slow = True
            before = server.chapter_calls
            card.get_by_role('button', name='继续更新').click()
            deadline = time.monotonic() + 10
            while server.chapter_calls == before and time.monotonic() < deadline:
                page.wait_for_timeout(20)
            assert server.chapter_calls > before
            assert card.get_by_role('button', name='移除本机副本').is_disabled()
            denied = page.evaluate("async()=>{const {offlineWorkerRequest}=await import('/js/offline-library.js');try {await offlineWorkerRequest('remove-offline-copy',{id:'fixture'});return '';} catch(e){return e.message;}}")
            assert '下载任务' in denied
            card.get_by_role('button', name='暂停下载').click()
            page.wait_for_function('document.querySelector(".offline-book-message")?.textContent.includes("已暂停")')
            server.slow = False
            result['checks'].append('active download excludes local removal; caller-owned cancellation keeps previous snapshot')

            step = 'offline inventory'
            page.evaluate("""async()=>{
              localStorage.setItem('resume:fixture',JSON.stringify({pos:321,cutoff:444,dirty:false}));
              localStorage.setItem('notebook:fixture',JSON.stringify([{id:'local',text:'本机个人摘记',dirty:false}]));
              localStorage.setItem('note-draft:fixture:3',JSON.stringify({text:'未保存草稿',cutoff:444}));
              const c=await caches.open('yedu-books-v1');
              await c.put('/api/books/fixture/notebook',new Response(JSON.stringify({items:[{id:'personal',revision:9,text:'后来更新的个人摘记'}]}),{headers:{'Content-Type':'application/json'}}));
            }""")
            personal = page.evaluate("Object.fromEntries(['resume:fixture','notebook:fixture','note-draft:fixture:3'].map(k=>[k,localStorage.getItem(k)]))")
            # DevTools network emulation can leave an already-running worker's network usable.
            # Make the fixture API explicitly unavailable so this proves cache-only behavior.
            server.api_unavailable = True
            context.set_offline(True)
            page.reload(wait_until='domcontentloaded')
            card = page.locator('.offline-book[data-book-id="fixture"]')
            card.get_by_role('heading', name='测试用书').wait_for()
            assert card.get_by_role('link', name='打开阅读').is_visible()
            assert card.get_by_role('button', name='检查更新').is_disabled()
            page.screenshot(path=str(out / 'offline-inventory-390.png'), full_page=True)
            result['checks'].append('offline reload retains book titles, actual availability and bounded network controls')

            step = 'safe offline copy removal'
            page.once('dialog', lambda dialog: dialog.accept())
            card.get_by_role('button', name='移除本机副本').click()
            page.wait_for_function('document.querySelector(".offline-library-notice")?.textContent.includes("本机副本已移除")')
            page.wait_for_function('document.querySelector(".offline-library-summary")?.textContent.startsWith("0 本")')
            assert personal == page.evaluate("Object.fromEntries(['resume:fixture','notebook:fixture','note-draft:fixture:3'].map(k=>[k,localStorage.getItem(k)]))")
            retained = page.evaluate("async()=>{const c=await caches.open('yedu-books-v1');return (await c.match('/api/books/fixture/notebook')).json()}")
            assert retained['items'][0]['revision'] == 9
            keys = page.evaluate('caches.keys()')
            assert not any(key.startswith('yedu-book-fixture@') for key in keys)
            cached_shelf = page.evaluate("async()=>{const c=await caches.open('yedu-books-v1');return (await c.match('/api/books')).json()}")
            assert any(book['id'] == 'fixture' for book in cached_shelf)
            assert page.evaluate("async()=> (await fetch('/api/books/fixture/chapters/0')).status") == 503
            result['checks'].append('offline copy removal clears only content; visible book, newer notebook, progress and drafts survive')
            assert server.writes == 0 and server.process_calls == 0 and not server.asks
            assert not result['page_errors'], result['page_errors']
            context.close()
            browser.close()
    except Exception:
        result['failed_step'] = step
        raise
    finally:
        server.shutdown()
        server.server_close()
        result['server_write_calls'] = server.writes
        result['manifest_calls'] = server.manifest_calls
        result['ok'] = 'failed_step' not in result and not result['page_errors']
        (out / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
