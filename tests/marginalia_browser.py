"""Browser acceptance for manual and automatic AI marginalia; all model output is synthetic."""
from __future__ import annotations

import argparse
import functools
import http.server
import json
from pathlib import Path
import threading
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright
import frontend_browser as base
import workspace_browser as workspace


class MarginaliaFixture(workspace.WorkspaceFixture):
    SPLIT = workspace.BLOCKS[18]['o']
    CHAPTERS = [
        {**base.CHAPTER, 'title': '测试上章', 'o1': SPLIT},
        {**base.CHAPTER, 'title': '测试下章', 'o0': SPLIT},
    ]

    def book(self):
        return {**super().book(), 'chapters': self.CHAPTERS}

    def do_GET(self):
        path = urlparse(self.path).path
        if path.startswith('/api/books/fixture/chapters/'):
            n = int(path.rsplit('/', 1)[-1])
            if n in (0, 1):
                blocks = workspace.BLOCKS[:18] if n == 0 else workspace.BLOCKS[18:]
                return self.data({**self.CHAPTERS[n], 'n': n, 'blocks': blocks, 'mentions': [], 'notes': {}})
        return super().do_GET()

    def do_POST(self):
        if urlparse(self.path).path != '/api/books/fixture/marginalia':
            return super().do_POST()
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if payload.get('mode') == 'cues':
            anchors = self.auto_anchors(payload['page_start'], payload['page_end'])
            with self.server.marginalia_lock:
                self.server.marginalia_calls.append(payload)
            return self.data({'items': [{'start': start, 'end': end,
                                         'quote': workspace.notes.source_quote(workspace.SOURCE, start, end),
                                         'persona': 'detective', 'kind': 'clue', 'score': .91}
                                        for start, end in anchors], 'reason': 'cues'})
        if payload.get('mode') == 'manual':
            start, end = payload['start'], payload['end']
        else:
            anchors = self.auto_anchors(payload['page_start'], payload['page_end'])
            if not anchors:
                with self.server.marginalia_lock:
                    self.server.marginalia_calls.append(payload)
                return self.data({'items': [], 'comment': None, 'reason': 'quiet', 'cached': False})
            start, end = anchors[0]
        quote = workspace.notes.source_quote(workspace.SOURCE, start, end)
        persona = payload.get('persona')
        if persona == 'auto':
            persona = 'detective'
        with self.server.marginalia_lock:
            self.server.marginalia_calls.append(payload)
        item = {'key': f'fixture-{len(self.server.marginalia_calls)}', 'comment':
                          '这道折痕，比一句解释更诚实。' if persona == 'detective' else '她收起的是纸，也是刚露头的情绪。',
                          'start': start, 'end': end, 'quote': quote, 'persona': persona,
                          'kind': 'manual' if payload.get('mode') == 'manual' else 'clue',
                          'score': .91, 'guard': {'verdict': 'ok', 'p': .94},
                          'position': payload['pos'], 'cached': False}
        if payload.get('mode') == 'auto':
            first = dict(item)
            item['items'] = [first,
                             {**first, 'persona': 'empathy', 'comment': '她把信收得这么紧，心里恐怕没那么平静。'},
                             {**first, 'persona': 'wit', 'comment': '这纸都快折没了，话倒还是在那儿。'}]
        return self.data(item)

    @staticmethod
    def auto_anchors(page_start, page_end):
        anchors = []
        for block in workspace.BLOCKS:
            lo, hi = max(page_start, block['o']), min(page_end, block['o'] + len(block['t']))
            if hi - lo < 14:
                continue
            for start in (lo, hi - 14):
                end = start + 14
                if any(abs(start - prior[0]) < 20 for prior in anchors):
                    continue
                try:
                    workspace.notes.source_quote(workspace.SOURCE, start, end)
                    anchors.append((start, end))
                    if len(anchors) == 2:
                        return anchors
                except ValueError:
                    pass
        return anchors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', default='/tmp/yedu-marginalia-browser')
    args = parser.parse_args()
    out = Path(args.out_dir).resolve(); out.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(MarginaliaFixture, directory=str(base.WEB)))
    server.note_lock = threading.Lock(); server.marginalia_lock = threading.Lock()
    server.notes, server.note_calls, server.marginalia_calls = [], 0, []
    server.hold_operation, server.held_once = None, False
    server.held, server.release = threading.Event(), threading.Event()
    server.progress = base.BASE_BOOK['progress'].copy()
    server.asks, server.upgrade, server.quality_pending, server.process_calls = [], False, False, 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_address[1]}'
    result = {'isolation': 'synthetic comments and book; no model or production-data access', 'checks': [], 'page_errors': []}
    step = 'launch'; page = None
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=['--no-proxy-server'])
            for width, height in [(390, 844), (1440, 900)]:
                server.notes, server.note_calls, server.marginalia_calls = [], 0, []
                server.progress = base.BASE_BOOK['progress'].copy()
                context = browser.new_context(locale='zh-CN',viewport={'width': width, 'height': height}, service_workers='block')
                context.add_init_script("localStorage.setItem('tip-shown','1');localStorage.setItem('settings',JSON.stringify({anim:false,aiComments:false,aiPersona:'auto'}))")
                context.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
                page = context.new_page(); page.set_default_timeout(18000)
                page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
                page.goto(origin + '/#/read/fixture', wait_until='networkidle')
                page.wait_for_function("document.querySelector('.folio')?.textContent.trim().length > 0")

                step = f'{width}: select exact source and choose voice'
                page.evaluate("document.querySelector('.reader').classList.add('ui')")
                page.locator('.dock button').filter(has_text='摘录').click()
                chosen = page.evaluate('''() => {
                  const info=JSON.parse(localStorage.getItem('resume:fixture'));
                  const el=[...document.querySelectorAll('.flow p[data-o]')].find(p=>{
                    const r=p.getBoundingClientRect(); return r.left>=0&&r.right<=innerWidth&&+p.dataset.o>=info.pos&&+p.dataset.o+14<=info.cutoff;
                  });
                  if(!el) throw Error('no visible selection fixture');
                  const node=document.createTreeWalker(el,NodeFilter.SHOW_TEXT).nextNode();
                  const range=document.createRange(); range.setStart(node,0); range.setEnd(node,14);
                  const selection=getSelection(); selection.removeAllRanges(); selection.addRange(range);
                  return {start:+el.dataset.o,end:+el.dataset.o+14,quote:range.toString()};
                }''')
                page.get_by_role('button', name='AI 批一句', exact=True).click()
                page.locator('.marginalia-composer').wait_for()
                assert chosen['quote'] in page.locator('.marginalia-composer blockquote').inner_text()
                page.get_by_role('button', name='侦探', exact=True).click()
                page.get_by_role('button', name='写一句', exact=True).click()
                page.locator('.marginalia-drawer-comment').wait_for()
                assert page.locator('.ai-underline').count() >= 1
                request = server.marginalia_calls[-1]
                assert (request['mode'], request['start'], request['end'], request['persona']) == ('manual', chosen['start'], chosen['end'], 'detective')
                assert '折痕' in page.locator('.marginalia-drawer-comment').inner_text()
                assert page.locator('.marginalia-drawer blockquote').count() == 0
                assert page.locator('.barrage-line').count() == 0
                page.screenshot(path=out / f'{width}-manual.png', full_page=True)
                result['checks'].append(f'{width}px: exact selected source opened a comment drawer, with no barrage')

                step = f'{width}: save generated comment to personal notebook'
                page.get_by_role('button', name='收进摘记', exact=True).click()
                page.wait_for_function("JSON.parse(localStorage.getItem('notebook:fixture')||'[]').some(n=>n.text.includes('AI · 侦探')&&!n.dirty)")
                saved = next(row for row in server.notes if 'AI · 侦探' in row['text'])
                assert (saved['start'], saved['end'], saved['quote']) == (chosen['start'], chosen['end'], chosen['quote'])
                result['checks'].append(f'{width}px: generated comment saved as a normal synchronized source-anchored note')

                step = f'{width}: switch persona on the same source'
                page.get_by_role('button', name='换个口吻', exact=True).click()
                page.get_by_role('button', name='吐槽', exact=True).click()
                page.get_by_role('button', name='写一句', exact=True).click()
                page.locator('.marginalia-drawer-comment').wait_for()
                assert server.marginalia_calls[-1]['persona'] == 'wit'
                result['checks'].append(f'{width}px: persona switch regenerated the same anchor without moving the reader')
                page.get_by_role('button', name='关闭评论', exact=True).click()

                step = f'{width}: enable on-demand cue mode'
                page.evaluate("document.querySelector('.reader').classList.add('ui')")
                page.locator('.dock button').filter(has_text='排版').click()
                pane = page.locator('.margin .pane' if width >= 1080 else '.sheet .pane')
                pane.get_by_role('switch', name='读者评论', exact=True).click()
                assert page.evaluate("JSON.parse(localStorage.getItem('settings')).aiComments") is True
                if width >= 1080:
                    page.locator('.margin').get_by_role('button', name='关闭').click()
                else:
                    page.keyboard.press('Escape')
                page.locator('.marginalia-cue').first.wait_for()
                page.wait_for_timeout(700)
                assert any(x['mode'] == 'cues' for x in server.marginalia_calls)
                assert not [x for x in server.marginalia_calls if x['mode'] == 'auto']
                assert page.locator('.marginalia-drawer:not([hidden])').count() == 0
                assert page.evaluate("getComputedStyle(document.querySelector('.marginalia-cue')).textDecorationStyle") == 'dashed'
                page.screenshot(path=out / f'{width}-cues.png', full_page=True)
                cue_style = page.locator('.marginalia-cue').first.evaluate('''el => ({
                  text: el.textContent, font: getComputedStyle(el).font, color: getComputedStyle(el).color,
                  underline: getComputedStyle(el).textDecorationStyle,
                })''')
                page.locator('.marginalia-cue').first.click()
                page.locator('.marginalia-drawer-comment').first.wait_for()
                assert page.locator('.marginalia-cue').first.evaluate('''el => ({
                  text: el.textContent, font: getComputedStyle(el).font, color: getComputedStyle(el).color,
                  underline: getComputedStyle(el).textDecorationStyle,
                })''') == cue_style
                assert page.locator('.marginalia-drawer blockquote').count() == 0
                assert page.locator('.marginalia-drawer-comment').count() == 3
                assert page.locator('.marginalia-drawer-save').count() == 3
                auto_calls = [x for x in server.marginalia_calls if x['mode'] == 'auto']
                assert len(auto_calls) == 1 and auto_calls[0]['purpose'] == 'visible', auto_calls
                assert auto_calls[0]['page_start'] < auto_calls[0]['page_end'] <= auto_calls[0]['pos']
                assert page.locator('.barrage-line').count() == 0
                assert page.locator('.marginalia-drawer').get_attribute('role') == 'dialog'
                page.screenshot(path=out / f'{width}-automatic.png', full_page=True)
                page.get_by_role('button', name='关闭评论', exact=True).click()
                page.locator('.marginalia-cue').first.click()
                page.locator('.marginalia-drawer-comment').first.wait_for()
                assert len([x for x in server.marginalia_calls if x['mode'] == 'auto']) == 1
                page.keyboard.press('Escape')
                assert page.locator('.marginalia-drawer:not([hidden])').count() == 0
                result['checks'].append(f'{width}px: Jev-only cues precede one on-tap writing request and closable comment drawer')

                step = f'{width}: page and chapter turns select cues but do not write comments'
                page.evaluate('document.activeElement?.blur()')
                previous_pos = page.evaluate("JSON.parse(localStorage.getItem('resume:fixture')).pos")
                page.keyboard.press('ArrowRight')
                page.wait_for_function("old => JSON.parse(localStorage.getItem('resume:fixture')).pos > old", arg=previous_pos)
                page.locator('.marginalia-cue').first.wait_for()
                assert page.locator('.marginalia-drawer:not([hidden])').count() == 0
                assert len([x for x in server.marginalia_calls if x['mode'] == 'auto']) == 1
                for _ in range(20):
                    current = page.evaluate("JSON.parse(localStorage.getItem('resume:fixture'))")
                    if current['pos'] >= MarginaliaFixture.SPLIT:
                        break
                    page.keyboard.press('ArrowRight')
                    page.wait_for_function('''old => JSON.parse(localStorage.getItem('resume:fixture')).pos > old''', arg=current['pos'])
                current = page.evaluate("JSON.parse(localStorage.getItem('resume:fixture'))")
                assert current['pos'] >= MarginaliaFixture.SPLIT, current
                assert len([x for x in server.marginalia_calls if x['mode'] == 'auto']) == 1
                page.locator('.marginalia-cue').first.wait_for()
                page.locator('.marginalia-cue').first.click()
                page.locator('.marginalia-drawer-comment').first.wait_for()
                assert len([x for x in server.marginalia_calls if x['mode'] == 'auto']) == 2
                result['checks'].append(f'{width}px: cross-chapter paging selects cues but writes no comment until tapped')

                assert not result['page_errors'], result['page_errors']
                context.close()
            step = 'touch: tap a cue without losing the drawer to the synthetic click'
            server.progress = base.BASE_BOOK['progress'].copy()
            touch = browser.new_context(locale='zh-CN',viewport={'width': 390, 'height': 844}, has_touch=True,
                                        is_mobile=True, service_workers='block')
            touch.add_init_script("localStorage.setItem('tip-shown','1');localStorage.setItem('settings',JSON.stringify({anim:false,aiComments:true,aiPersona:'auto'}))")
            touch.route('**/*', lambda route: route.continue_() if route.request.url.startswith(origin + '/') else route.abort())
            page = touch.new_page(); page.set_default_timeout(18000)
            page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
            page.goto(origin + '/#/read/fixture', wait_until='networkidle')
            page.locator('.marginalia-cue').first.wait_for()
            page.locator('.marginalia-cue').first.tap()
            page.locator('.marginalia-drawer-comment').first.wait_for()
            assert page.locator('.marginalia-drawer:not([hidden])').count() == 1
            assert page.locator('.marginalia-drawer blockquote').count() == 0
            result['checks'].append('touch: tapping a cue keeps the comment drawer open')
            touch.close()
            browser.close()
    except Exception as error:
        if page:
            try: page.screenshot(path=out / 'failure.png', full_page=True)
            except Exception: pass
        raise AssertionError(f'failed at {step}: {error}') from error
    finally:
        server.shutdown(); server.server_close()
    (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
