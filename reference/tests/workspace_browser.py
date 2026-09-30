"""Synthetic acceptance for personal reading workspace; no real books or model calls.

Uses the existing loopback book fixture and the real notebook validation/apply
function for note writes. Browser contexts are isolated per viewport. Offline
checks disable Chromium networking and verify the durable client outbox.
"""
from __future__ import annotations

import argparse
import copy
import functools
import http.server
import json
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright
import frontend_browser as base

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from server import notebook as notes  # Pure validation/storage transformation only.

BLOCKS = copy.deepcopy(base.blocks)
for block in BLOCKS:
    # Replace two BMP units with an astral character without changing source offsets.
    block['t'] = '😀' + block['t'][2:]
SOURCE = {'blocks': BLOCKS, 'len': base.at}


class WorkspaceFixture(base.Fixture):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/api/books/fixture/chapters/0':
            return self.data({**base.CHAPTER, 'n': 0, 'blocks': BLOCKS, 'mentions': [], 'notes': {}})
        if path == '/api/books/fixture/offline-manifest':
            return self.data({'version': 'fixture-workspace-v1', 'book': self.book(),
                              'chapters': [{'n': 0, 'url': '/api/books/fixture/chapters/0', 'images': ['/api/books/fixture/img/test.svg']}],
                              'assets': ['/api/books/fixture/img/cover.svg'],
                              'graph': {'url': f'/api/books/fixture/kg?from=-1&to={base.at}', 'to': base.at},
                              'notebook': {'url': '/api/books/fixture/notebook'}, 'frontier': base.at, 'state': 'done'})
        if path == '/api/books/fixture/notebook':
            with self.server.note_lock:
                return self.data({'items': copy.deepcopy(self.server.notes)})
        if path == '/api/books/fixture/notebook.md':
            return self.send_body('# Synthetic notebook', 'text/markdown')
        return super().do_GET()

    def do_PUT(self):
        if urlparse(self.path).path != '/api/books/fixture/notebook':
            return super().do_PUT()
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        with self.server.note_lock:
            try:
                updated, item, conflict = notes.apply(self.server.notes, payload, SOURCE)
            except ValueError as error:
                return self.data({'error': str(error)}, 400)
            self.server.note_calls += 1
            if conflict:
                return self.data({'error': '这条摘记已在其他设备修改', 'item': item}, 409)
            self.server.notes = updated
            hold = payload.get('operation') == self.server.hold_operation and not self.server.held_once
            if hold:
                self.server.held_once = True
                self.server.held.set()
        if hold and not self.server.release.wait(10):
            return self.data({'error': 'Synthetic delayed response was not released'}, 503)
        return self.data({'item': item})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', default='/tmp/yedu-workspace-browser')
    parser.add_argument('--skip-preview', action='store_true', help='Development only: report preview as pending instead of checking it')
    args = parser.parse_args()
    out = Path(args.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(WorkspaceFixture, directory=str(base.WEB)))
    server.note_lock = threading.Lock()
    server.notes, server.note_calls = [], 0
    server.hold_operation, server.held_once = None, False
    server.held, server.release = threading.Event(), threading.Event()
    server.progress = base.BASE_BOOK['progress'].copy()
    server.asks, server.upgrade, server.quality_pending, server.process_calls = [], False, False, 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_address[1]}'
    result = {'isolation': 'loopback synthetic book, real notebook apply validation, no production data or models', 'checks': [], 'page_errors': []}
    page = None
    step = 'launch'
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=['--no-proxy-server'])
            for width, height in [(390, 844), (1440, 900)]:
                server.notes, server.note_calls = [], 0
                server.progress = base.BASE_BOOK['progress'].copy()
                context = browser.new_context(locale='zh-CN',viewport={'width': width, 'height': height}, service_workers='block')
                context.add_init_script("localStorage.setItem('tip-shown','1'); localStorage.setItem('settings',JSON.stringify({anim:false}))")
                context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
                page = context.new_page()
                page.set_default_timeout(15000)
                page.on('pageerror', lambda error: result['page_errors'].append(str(error)))

                def record(message):
                    result['checks'].append(f'{width}px: {message}')

                def pane():
                    return page.locator('.margin .pane' if width >= 1080 else '.sheet .pane')

                def resume():
                    return page.evaluate("JSON.parse(localStorage.getItem('resume:fixture'))")

                def close_pane():
                    if pane().locator('.pane-nav button').count() and (width >= 1080 or page.locator('.sheet.open').count()):
                        # Root navigation can have a stack. Native Back follows the same stack.
                        page.evaluate('while(window.YeduReader.onNativeBack()) { if(!document.querySelector(".sheet.open") && !document.querySelector(".margin .pane-nav button")) break; }')

                def open_menu():
                    if 'ui' not in page.locator('.reader').get_attribute('class').split():
                        page.get_by_role('button', name='打开阅读菜单', exact=True).click()

                def open_pane(label):
                    close_pane()
                    open_menu()
                    page.locator('.dock button').filter(has_text=label).click()

                def ready():
                    page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length > 0")

                def jump(page_number):
                    open_pane('目录')
                    pane().locator('.jump input').fill(str(page_number))
                    pane().locator('.jump button').click()
                    page.wait_for_function("n => Number(document.querySelector('.folio').firstChild.textContent) === n", arg=page_number)
                    close_pane()

                step = f'{width}: bookmark save and reload'
                page.goto(origin + '/#/read/fixture', wait_until='networkidle')
                ready()
                first = resume()
                open_menu()
                page.get_by_role('button', name='收藏当前页为书签', exact=True).click()
                page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')||'[]').some(n=>n.kind==='bookmark'&&!n.dirty)")
                bookmarks = [n for n in server.notes if n['kind'] == 'bookmark']
                assert len(bookmarks) == 1 and bookmarks[0]['start'] == first['pos']
                page.reload(wait_until='networkidle'); ready(); open_pane('摘记')
                assert pane().locator('.notebook-card').count() == 1
                assert '书签' in pane().locator('.note-source').inner_text()
                record('bookmark saved at the exact page anchor and restored after reload')
                if not args.skip_preview:
                    saved_position = resume()['pos']
                    pane().locator('.note-source').first.click()
                    pane().locator('.source-preview-jump').wait_for()
                    assert resume()['pos'] == saved_position
                    pane().locator('.source-preview-back').click()
                    record('zero-length bookmark anchors open a usable source preview')

                step = f'{width}: real DOM selection to saved quote'
                open_pane('摘录')
                selection = page.evaluate('''() => {
                  const info=JSON.parse(localStorage.getItem('resume:fixture'));
                  const ps=[...document.querySelectorAll('.flow p[data-o]')];
                  const el=ps.find(p=>+p.dataset.o>=info.pos && +p.dataset.o+14<=info.cutoff);
                  if(!el) throw Error('fixture has no fully visible text prefix');
                  const walker=document.createTreeWalker(el,NodeFilter.SHOW_TEXT), node=walker.nextNode();
                  if(!node || node.length<14)throw Error('fixture has no text node');
                  const range=document.createRange();range.setStart(el,0);range.setEnd(node,14);
                  const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
                  return {quote:range.toString(),start:+el.dataset.o,end:+el.dataset.o+14};
                }''')
                page.get_by_role('button', name='记一笔', exact=True).click()
                assert pane().locator('.note-quote').inner_text() == selection['quote']
                assert selection['quote'].startswith('😀')
                pane().get_by_role('textbox', name='我的想法', exact=True).fill('SELECTED_ORIGINAL_THOUGHT')
                page.set_viewport_size({'width': width, 'height': height - 220})
                page.wait_for_timeout(500)
                assert pane().get_by_role('textbox', name='我的想法', exact=True).input_value() == 'SELECTED_ORIGINAL_THOUGHT', 'keyboard/viewport resize destroyed the active editor'
                page.set_viewport_size({'width': width, 'height': height})
                page.wait_for_timeout(500)
                assert pane().get_by_role('textbox', name='我的想法', exact=True).input_value() == 'SELECTED_ORIGINAL_THOUGHT'
                record('keyboard-like viewport resize preserved the active note editor and its draft')
                pane().get_by_role('button', name='保存摘记', exact=True).click()
                page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')||'[]').some(n=>n.text==='SELECTED_ORIGINAL_THOUGHT'&&!n.dirty)")
                selected = next(n for n in server.notes if n['text'] == 'SELECTED_ORIGINAL_THOUGHT')
                assert [selected['start'], selected['end'], selected['quote']] == [selection['start'], selection['end'], selection['quote']]
                record('a real DOM Range with an element boundary and astral character saved the exact quote and UTF-16 anchors')

                step = f'{width}: offline note durability and reconnect'
                context.set_offline(True)
                pane().get_by_role('button', name='写下此刻的想法', exact=True).click()
                pane().get_by_role('textbox', name='我的想法', exact=True).fill('OFFLINE_DURABLE_THOUGHT')
                pane().get_by_role('button', name='保存摘记', exact=True).click()
                page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')||'[]').some(n=>n.text==='OFFLINE_DURABLE_THOUGHT'&&n.dirty)")
                assert not any(n['text'] == 'OFFLINE_DURABLE_THOUGHT' for n in server.notes)
                assert 'OFFLINE_DURABLE_THOUGHT' in pane().inner_text()
                context.set_offline(False)
                page.reload(wait_until='networkidle'); ready()
                page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')||'[]').some(n=>n.text==='OFFLINE_DURABLE_THOUGHT'&&!n.dirty)")
                assert any(n['text'] == 'OFFLINE_DURABLE_THOUGHT' for n in server.notes)
                record('offline note was durable locally, survived reload, and synchronized on reconnect')

                step = f'{width}: cutoff rewind updates an open notebook'
                current_page = int(page.locator('.folio').inner_text().split()[0])
                total_pages = int(page.locator('.folio').inner_text().split()[-1])
                jump(min(total_pages, current_page + 3))
                open_pane('摘记')
                assert 'SELECTED_ORIGINAL_THOUGHT' in pane().inner_text(), (resume(), selected)
                for _ in range(20):
                    prior = resume()['cutoff']
                    page.evaluate('document.activeElement.blur()')
                    page.keyboard.press('PageUp')
                    page.wait_for_function("p=>JSON.parse(localStorage.getItem('resume:fixture')).cutoff<p", arg=prior)
                    if resume()['cutoff'] < selected['knowledge_cutoff']:
                        break
                else:
                    raise AssertionError('failed to rewind before the note knowledge cutoff')
                page.wait_for_function("!document.querySelector('.notebook-list')?.textContent.includes('SELECTED_ORIGINAL_THOUGHT')")
                record('rewind immediately hid later notes while the notebook pane stayed open')

                step = f'{width}: remote conflict and draft spoiler boundaries'
                # Inject realistic durable synchronization state without making network/model calls.
                early = {'id': 'early-note-0001', 'operation': 'early-operation-01', 'kind': 'note', 'start': 0, 'end': 0, 'quote': '', 'text': 'EARLY_SAFE_THOUGHT', 'knowledge_cutoff': 0, 'revision': 1, 'created': 1, 'updated': 1}
                conflict = {**early, 'id': 'conflict-note-0001', 'operation': 'conflict-operation-01', 'text': 'EARLY_CONFLICT_THOUGHT', 'dirty': True, 'conflict': {'item': {**early, 'revision': 2, 'knowledge_cutoff': base.at, 'text': 'FUTURE_REMOTE_CONFLICT'}}}
                page.evaluate('''({early,conflict,end})=>{
                  const rows=JSON.parse(localStorage.getItem('notebook:fixture')||'[]').filter(n=>![early.id,conflict.id].includes(n.id));
                  localStorage.setItem('notebook:fixture',JSON.stringify([...rows,early,conflict]));
                  localStorage.setItem('note-draft:fixture:'+early.id,JSON.stringify({text:'FUTURE_UNSAVED_DRAFT',cutoff:end}));
                  dispatchEvent(new CustomEvent('yedu-notebook',{detail:'fixture'}));
                }''', {'early': early, 'conflict': conflict, 'end': base.at})
                assert 'FUTURE_REMOTE_CONFLICT' not in pane().inner_text()
                assert 'EARLY_CONFLICT_THOUGHT' not in pane().inner_text()
                pane().locator('.notebook-card').filter(has_text='EARLY_SAFE_THOUGHT').get_by_role('button', name='编辑', exact=True).click()
                assert pane().get_by_role('textbox', name='我的想法', exact=True).count() == 0
                assert 'FUTURE_UNSAVED_DRAFT' not in pane().inner_text()
                pane().get_by_role('button', name='查看后来的草稿（可能剧透）', exact=True).click()
                assert pane().get_by_role('textbox', name='我的想法', exact=True).input_value() == 'FUTURE_UNSAVED_DRAFT'
                assert page.evaluate("JSON.parse(localStorage.getItem('note-draft:fixture:early-note-0001')).text") == 'FUTURE_UNSAVED_DRAFT'
                record('later conflict content stayed hidden and an unsaved future draft required explicit reveal without deletion')

                step = f'{width}: search source preview preserves reading progress'
                jump(5)
                open_pane('目录')
                pane().get_by_role('button', name='搜索原文', exact=True).click()
                pane().get_by_role('searchbox', name='搜索原文', exact=True).fill('😀')
                pane().get_by_role('button', name='搜索', exact=True).click()
                page.wait_for_function("document.querySelectorAll('.reader-search-results li').length>0")
                before = resume()
                before_return = page.locator('.back-chip').is_visible()
                if not args.skip_preview:
                    pane().locator('.reader-search-results li button').first.click()
                    # The source preview's explicit jump is the only action allowed to move the reader.
                    pane().locator('.source-preview-jump').wait_for()
                    pane().locator('.source-preview-content mark').first.wait_for()
                    after = resume()
                    assert (before['pos'], before['cutoff']) == (after['pos'], after['cutoff'])
                    assert page.locator('.back-chip').is_visible() == before_return
                    pane().locator('.source-preview-jump').click()
                    page.wait_for_function("p=>JSON.parse(localStorage.getItem('resume:fixture')).pos!==p", arg=before['pos'])
                    record('search result preview preserved progress; explicit jump moved the reader and retained a return path')
                    assert page.locator('.back-chip').is_visible()
                    page.wait_for_timeout(400)  # Let closing-sheet and page-transform animations finish.
                    geometry = page.locator('.back-chip').bounding_box()
                    svg = page.locator('.back-chip svg').bounding_box()
                    assert geometry['height'] <= 60 and svg['width'] <= 24, (geometry, svg)
                    page.locator('.back-chip').click()
                    page.wait_for_function("p=>JSON.parse(localStorage.getItem('resume:fixture')).pos===p", arg=before['pos'])
                    assert not page.locator('.back-chip').is_visible()
                    assert page.evaluate("() => {const f=document.querySelector('.flow');return Math.abs(new DOMMatrixReadOnly(getComputedStyle(f).transform).m41-new DOMMatrixReadOnly(f.style.transform).m41)<.5;}"), 'disabled animation must also apply to source jumps and return'
                    record('the compact return control restored the exact pre-preview reading anchor')
                else:
                    result.setdefault('pending', []).append(f'{width}px source preview explicitly skipped for development')

                if width == 1440:
                    step = '1440: independent-tab late acknowledgement race'
                    race = {'id': 'race-note-0001', 'operation': 'race-operation-01', 'kind': 'note', 'start': 0, 'end': 0, 'quote': '', 'text': 'RACE_A', 'knowledge_cutoff': 0, 'revision': 0, 'expected_revision': 0, 'dirty': True, 'created': 1, 'updated': 1}
                    page.evaluate('''race=>{
                      const rows=JSON.parse(localStorage.getItem('notebook:fixture')||'[]');
                      localStorage.setItem('notebook:fixture',JSON.stringify([...rows,race]));
                      window.raceRegressed=false;
                      addEventListener('storage',e=>{if(e.key==='notebook:fixture'&&window.raceArmed){const n=JSON.parse(e.newValue).find(x=>x.id===race.id);if(n&&n.revision<2)window.raceRegressed=true;}});
                    }''', race)
                    server.hold_operation, server.held_once = race['operation'], False
                    server.held.clear(); server.release.clear()
                    second = context.new_page()
                    second.on('pageerror', lambda error: result['page_errors'].append(str(error)))
                    second.goto(origin + '/#/read/fixture', wait_until='domcontentloaded')
                    deadline = time.monotonic() + 5
                    while not server.held.is_set() and time.monotonic() < deadline:
                        second.wait_for_timeout(50)  # Keep Playwright route callbacks moving.
                    assert server.held.is_set(), 'second tab never started the held operation'
                    page.evaluate("async()=>{const {syncNotes}=await import('/js/notebook.js');await syncNotes('fixture')}")
                    page.evaluate("async()=>{const {Notebook}=await import('/js/notebook.js');const n=new Notebook({id:'fixture',version:'fixture-v1'});const old=n.items.find(x=>x.id==='race-note-0001');await n.save({...old,text:'RACE_B'});await n.sync();}")
                    page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')).some(n=>n.id==='race-note-0001'&&n.revision===2&&!n.dirty)")
                    page.evaluate('window.raceArmed=true')
                    server.release.set()
                    second.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')).some(n=>n.id==='race-note-0001'&&n.revision===2&&!n.dirty)")
                    second.wait_for_load_state('networkidle')
                    assert not page.evaluate('window.raceRegressed'), 'late acknowledgement regressed a newer notebook revision'
                    race_after = page.evaluate("JSON.parse(localStorage.getItem('notebook:fixture')).find(n=>n.id==='race-note-0001')")
                    assert race_after['text'] == 'RACE_B' and race_after['revision'] == 2 and not race_after.get('conflict')
                    second.close()
                    record('a delayed acknowledgement from another tab never regressed or conflicted a newer saved note')

                step = f'{width}: viewport and browser error checks'
                assert page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), 'horizontal document overflow'
                if width >= 1080:
                    assert page.locator('.margin').is_visible()
                page.screenshot(path=str(out / f'workspace-{width}.png'), full_page=True)
                record('viewport has no horizontal document overflow')
                context.close()
            step = 'fresh offline snapshot includes personal notes before first read'
            server.notes, _, _ = notes.apply([], {
                'id': 'snapshot-note-0001', 'operation': 'snapshot-operation-01', 'kind': 'note',
                'start': 0, 'end': 0, 'quote': '', 'text': 'FROM_OFFLINE_PACKAGE',
                'knowledge_cutoff': 0, 'expected_revision': 0,
            }, SOURCE)
            offline_context = browser.new_context(locale='zh-CN',viewport={'width': 390, 'height': 844})
            offline_context.add_init_script("localStorage.setItem('tip-shown','1')")
            offline_context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page = offline_context.new_page()
            page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
            page.goto(origin + '/', wait_until='networkidle')
            page.evaluate("navigator.serviceWorker.ready.then(()=>navigator.serviceWorker.controller?true:new Promise(r=>navigator.serviceWorker.addEventListener('controllerchange',()=>r(true),{once:true})))")
            assert page.evaluate("localStorage.getItem('notebook:fixture')") is None, 'fresh shelf must not have opened the notebook'
            page.evaluate("async()=>{const {downloadBook}=await import('/js/offline.js');await downloadBook('fixture',()=>{})}")
            # Clear only this isolated context to prove the book snapshot supplies the note.
            page.evaluate("localStorage.removeItem('notebook:fixture')")
            note_calls_before = server.note_calls
            offline_context.set_offline(True)
            page.goto(origin + '/#/read/fixture', wait_until='domcontentloaded')
            page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length>0")
            page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')||'[]').some(n=>n.text==='FROM_OFFLINE_PACKAGE')")
            page.get_by_role('button', name='打开阅读菜单', exact=True).click()
            page.locator('.dock button').filter(has_text='摘记').click()
            page.locator('.sheet .notebook-card').filter(has_text='FROM_OFFLINE_PACKAGE').wait_for()
            assert server.note_calls == note_calls_before, 'offline hydration must not write notes to the server'
            result['checks'].append('fresh complete-book download restored personal notes offline before the book was first opened')
            page.screenshot(path=str(out / 'offline-notebook-390.png'), full_page=True)
            offline_context.close()
            assert not result['page_errors'], result['page_errors']
            assert server.process_calls == 0 and not server.asks, 'workspace interactions must not call models'
            result['ok'] = not result.get('pending')
            browser.close()
    except Exception as error:
        result.update(ok=False, failed_step=step, error=f'{type(error).__name__}: {error}')
        if page and not page.is_closed():
            try:
                page.screenshot(path=str(out / 'failure.png'), full_page=True)
                (out / 'failure-body.txt').write_text(page.locator('body').inner_text())
            except Exception:
                pass
        raise
    finally:
        server.release.set()
        server.shutdown()
        (out / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
