"""Real HTTP + browser acceptance of the connected personal library workflows."""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import sys
import traceback

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import frontend_browser as content
import test_server_repair as fixtures
from server import app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', required=True)
    args = parser.parse_args()
    out = Path(args.out_dir); out.mkdir(parents=True, exist_ok=True)
    fixture = fixtures.HTTPRepair('test_upload_never_calls_judge_and_concurrent_same_upload_is_idempotent')
    fixture.setUp()
    app.WEB = ROOT / 'web'
    for bid, title in [('fixture', '清晨与书页'), ('second', '窗边的故事'), ('hidden', 'INTERNAL_HIDDEN_COPY')]:
        directory = fixture.make_book(bid)
        source = {'title': title, 'author': '测试作者', 'lang': 'zh', 'genre': 'novel', 'len': content.at,
                  'blocks': copy.deepcopy(content.blocks), 'notes': {},
                  'chapters': [{**content.CHAPTER, 'b0': 0, 'b1': len(content.blocks)}]}
        app.wjson(directory / 'book.json', source)
        app.wjson(directory / 'status.json', {'state': 'done', 'frontier': content.at})
        app.wjson(directory / 'kg.json', {'log': []})
        if bid == 'hidden':
            app.wjson(directory / 'meta.json', {'hidden': True})
        app.wjson(directory / 'notebook.json', [{'id': 'note-browser-001', 'kind': 'note', 'start': 0, 'end': 8,
                   'quote': content.blocks[0]['t'][:8], 'text': '云端的清晨想法' if bid == 'fixture' else '另一扇窗',
                   'knowledge_cutoff': 2000, 'revision': 1, 'operation': 'operation-browser-001', 'created': 100, 'updated': 100}])
    app.wjson(fixture.root / 'progress.json', {'fixture': {'pos': 1000, 'cutoff': 1500, 'pct': 20, 't': 100}})
    origin = f'http://127.0.0.1:{fixture.server.server_port}'
    result = {'checks': [], 'page_errors': [], 'isolation': 'real application HTTP server; temporary synthetic books; disabled worker; external models forbidden'}
    page = None
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=['--no-proxy-server'])
            context = browser.new_context(locale='zh-CN',viewport={'width': 390, 'height': 844})
            context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page = context.new_page(); page.set_default_timeout(20000)
            page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
            page.goto(origin, wait_until='networkidle')
            page.wait_for_function('!!navigator.serviceWorker.controller')
            assert page.get_by_role('navigation', name='书房导航').count() == 1
            assert page.locator('.library-card').count() == 2
            page.get_by_role('button', name='《清晨与书页》书籍菜单').click()
            page.get_by_role('button', name='加入接下来读', exact=False).click()
            page.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1') || '{}').items?.includes('fixture')")
            page.keyboard.press('Escape')
            page.get_by_role('navigation', name='书房导航').get_by_role('link', name='接下来读').click()
            page.locator('.reading-list-order [data-list-book="fixture"]').first.wait_for()
            page.locator('.reading-list-add summary').click()
            page.get_by_role('button', name='加入《窗边的故事》', exact=True).click()
            page.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1') || '{}').items?.length === 2")
            page.get_by_role('button', name='将《窗边的故事》上移').click()
            page.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1') || '{}').items?.[0] === 'second' && !JSON.parse(localStorage.getItem('reading-list-v1') || '{}').dirty")
            assert json.loads(fixture.request('GET', '/api/reading-list')[2])['items'] == ['second', 'fixture']
            result['checks'].append('shelf menu adds an explicit book; queue picker, reorder and real server persistence agree')

            # Independent browser context models another device with its own durable outbox.
            other_context = browser.new_context(locale='zh-CN',viewport={'width': 1440, 'height': 1000}, service_workers='block')
            other_context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            other = other_context.new_page(); other.set_default_timeout(20000)
            other.goto(origin + '/#/next', wait_until='networkidle')
            assert other.locator('.reading-list-book').count() == 2
            context.set_offline(True)
            page.get_by_role('button', name='将《清晨与书页》上移').click()
            page.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1')).dirty")
            page.reload(wait_until='domcontentloaded')
            page.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1')).items[0] === 'fixture'")
            page.locator('.reading-list-book').first.wait_for()
            assert page.locator('.reading-list-sync').inner_text().find('联网后') >= 0
            other.get_by_role('button', name='将《清晨与书页》移出清单').click()
            other.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1')).items.length === 1 && !JSON.parse(localStorage.getItem('reading-list-v1')).dirty")
            context.set_offline(False)
            page.locator('.reading-list-conflict:not([hidden])').wait_for()
            assert page.locator('.reading-list-book').count() == 2
            page.get_by_role('button', name='使用另一设备顺序', exact=True).click()
            page.wait_for_function("JSON.parse(localStorage.getItem('reading-list-v1')).items.length === 1 && !JSON.parse(localStorage.getItem('reading-list-v1')).conflict")
            result['checks'].append('offline edits survive reload; separate device edit yields visible conflict and explicit choice')
            page.screenshot(path=str(out / 'next-390.png'), full_page=True)
            other_context.close()

            # The all-notes scope is intentional; preview must not mutate progress or durable notes.
            before_progress = json.loads(fixture.request('GET', '/api/books/fixture')[2])['progress']
            page.get_by_role('navigation', name='书房导航').get_by_role('link', name='全部摘记').click()
            page.wait_for_function("document.querySelectorAll('.nh-card').length === 2")
            assert '包含后文想法' in page.locator('.nh-scope').inner_text()
            assert 'INTERNAL_HIDDEN_COPY' not in page.locator('body').inner_text()
            page.get_by_role('searchbox', name='搜索全部个人摘记').fill('另一扇窗')
            assert page.locator('.nh-card').count() == 1
            page.get_by_role('searchbox', name='搜索全部个人摘记').fill('')
            page.locator('.nh-card[data-book="fixture"]').get_by_role('button', name='查看原文').click()
            page.get_by_role('link', name='转到这里阅读', exact=True).wait_for()
            assert json.loads(fixture.request('GET', '/api/books/fixture')[2])['progress'] == before_progress
            assert '/#/notes' in page.url
            assert page.evaluate('window.YeduReader.onNativeBack()') is True
            page.wait_for_function("!document.querySelector('dialog[open]')")
            history_length = page.evaluate('history.length')
            assert page.evaluate('window.YeduReader.onNativeBack()') is False
            assert page.evaluate('history.length') == history_length and '/#/notes' in page.url
            result['checks'].append('all-notes scope, cross-book search and source preview work without changing saved progress; native Back closes preview')
            page.screenshot(path=str(out / 'notes-390.png'), full_page=True)

            for width in [320, 390, 1440]:
                page.set_viewport_size({'width': width, 'height': 900})
                for route in ['#/', '#/next', '#/notes', '#/offline']:
                    page.goto(origin + '/' + route, wait_until='networkidle')
                    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), (width, route)
                page.screenshot(path=str(out / f'offline-{width}.png'), full_page=True)
            result['checks'].append('all four workspace destinations fit 320, 390 and 1440px viewports')

            # Each direct route must reach the existing login gate, not a false empty state.
            app.PASSCODE = 'synthetic-route-passcode'
            auth_context = browser.new_context(locale='zh-CN',service_workers='block')
            auth_context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            auth_page = auth_context.new_page(); auth_page.set_default_timeout(15000)
            for route in ['#/next', '#/notes', '#/offline']:
                auth_page.goto(origin + '/' + route, wait_until='domcontentloaded')
                auth_page.get_by_label('书房口令').wait_for()
            app.PASSCODE = ''
            auth_context.close()
            result['checks'].append('direct queue, notebook and offline URLs show password entry when authentication is required')
            assert not result['page_errors'], result['page_errors']
            result['ok'] = True
            browser.close()
    except Exception as error:
        result['ok'] = False; result['failure'] = str(error)
        result['traceback'] = traceback.format_exc()
        if page:
            try: page.screenshot(path=str(out / 'failure.png'), full_page=True)
            except Exception: pass
    finally:
        fixture.doCleanups()
        (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    raise SystemExit(main())
