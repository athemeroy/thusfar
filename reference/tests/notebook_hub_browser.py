"""Isolated cross-book notebook interaction checks; no production data or models."""
import argparse
import functools
import http.server
import json
from pathlib import Path
import threading
import time
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
TEXT='😀甲和乙在书页上留下想法。后来他们重新读到这里。'
LENGTH=len(TEXT.encode('utf-16-le'))//2
CHAPTER={'title':'原文所在章节','o0':0,'o1':LENGTH,'kind':'body','spoil':False}
BOOKS=[{'id':'book-a','title':'远山与夜色','author':'测试作者甲'}, {'id':'book-b','title':'另一种生活','author':'测试作者乙'}, {'id':'book-empty','title':'还没有摘记的书'}, {'id':'hidden-book','title':'HIDDEN_BOOK_SECRET','hidden':True}]
NOTE={'id':'note-local','kind':'note','start':2,'end':3,'quote':'甲','text':'LOCAL_PENDING_THOUGHT','revision':1,'dirty':True,'updated':1700000000}
REMOTE=[{**NOTE,'dirty':False,'revision':3,'text':'REMOTE_STALE_THOUGHT'}, {**NOTE,'id':'note-remote','dirty':False,'start':4,'end':5,'quote':'乙','text':'远山里的另一句话','updated':1700000001}]
class Fixture(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*_):pass
    def send(self,value,status=200,kind='application/json'):
        if not isinstance(value,bytes):value=json.dumps(value,ensure_ascii=False).encode()
        self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(value)));self.end_headers()
        try:self.wfile.write(value)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        path=urlparse(self.path).path
        if path=='/harness':return self.send(b'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/css/app.css"><link rel="stylesheet" href="/css/notebook-hub.css"><main id="app"></main>',kind='text/html')
        if path=='/api/books':return self.send({'error':'需要口令'},401) if self.server.auth else self.send(BOOKS)
        if path.endswith('/notebook'):
            self.server.notebook_ids.append(path.split('/')[3]);time.sleep(.06)
            if path=='/api/books/book-b/notebook' and self.server.unavailable:return self.send({'error':'本机没有下载本书摘记'},503)
            return self.send({'items':REMOTE if path=='/api/books/book-a/notebook' else []})
        if path=='/api/books/book-a':return self.send({**BOOKS[0],'len':LENGTH,'version':'book-v1','chapters':[CHAPTER]})
        if path=='/api/books/book-a/chapters/0':
            self.server.chapter_calls+=1
            if self.server.delay:time.sleep(.35)
            text=TEXT.replace('甲','错') if self.server.mismatch else TEXT
            return self.send({**CHAPTER,'blocks':[{'k':'p','o':0,'t':text}]})
        if path.startswith('/api/'):return self.send({'error':'Unexpected fixture endpoint'},404)
        return super().do_GET()
    def do_PUT(self):self.server.writes+=1;return self.send({'error':'Writes forbidden'},405)
    do_POST=do_PUT

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--out-dir',default='/tmp/yedu-notebook-hub-browser');args=parser.parse_args()
    out=Path(args.out_dir);out.mkdir(parents=True,exist_ok=True)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Fixture,directory=str(ROOT/'web')))
    server.auth=False;server.unavailable=True;server.mismatch=False;server.delay=False;server.notebook_ids=[];server.chapter_calls=0;server.writes=0
    threading.Thread(target=server.serve_forever,daemon=True).start();origin=f'http://127.0.0.1:{server.server_address[1]}'
    result={'checks':[],'page_errors':[],'isolation':'Synthetic loopback book/notes only; API mutations forbidden'}
    try:
      with sync_playwright() as p:
        browser=p.chromium.launch(headless=True,args=['--no-proxy-server'])
        for width in (390,1440):
            server.unavailable=True;server.mismatch=False;server.delay=False
            context=browser.new_context(locale='zh-CN',viewport={'width':width,'height':900},service_workers='block')
            context.route('**/*',lambda route:route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
            page=context.new_page();page.on('pageerror',lambda e:result['page_errors'].append(str(e)));page.goto(origin+'/harness')
            page.evaluate('''async ({note})=>{
              localStorage.setItem('notebook:book-a',JSON.stringify([note]));
              localStorage.setItem('notebook:book-b',JSON.stringify([{...note,id:'offline-bookmark',kind:'bookmark',start:0,end:0,quote:'',text:'BOOK_B_OFFLINE',dirty:true}]));
              localStorage.setItem('notebook:hidden-book',JSON.stringify([{...note,text:'HIDDEN_LOCAL_SECRET'}]));
              localStorage.setItem('notebook:unlisted-book',JSON.stringify([{...note,text:'UNLISTED_LOCAL_SECRET'}]));
              localStorage.setItem('resume:book-a',JSON.stringify({pos:17,cutoff:22,pct:30}));
              window.beforeStorage=JSON.stringify({...localStorage});
              window.controller=new AbortController();const {openNotebookHub}=await import('/js/notebook-hub.js');
              window.dispose=await openNotebookHub(document.querySelector('#app'),{signal:controller.signal});
            }''',{'note':NOTE})
            page.wait_for_function("document.querySelector('.nh-loading summary')?.textContent.includes('2 / 3 本已读取')")
            assert page.locator('.nh-card').count()==3
            assert 'LOCAL_PENDING_THOUGHT' in page.locator('.nh-cards').inner_text()
            assert 'REMOTE_STALE_THOUGHT' not in page.locator('.nh-cards').inner_text()
            assert 'HIDDEN_LOCAL_SECRET' not in page.locator('body').inner_text() and 'UNLISTED_LOCAL_SECRET' not in page.locator('body').inner_text()
            assert 'hidden-book' not in server.notebook_ids and 'unlisted-book' not in server.notebook_ids
            assert '包含后文想法' in page.locator('.nh-scope').inner_text()
            page.locator('.nh-loading summary').click()
            assert '先显示本机 1 条' in page.locator('.nh-load-rows').inner_text()
            server.unavailable=False;page.locator('.nh-load-row').filter(has_text='另一种生活').get_by_role('button',name='重试',exact=True).click()
            page.wait_for_function("document.querySelector('.nh-loading summary')?.textContent.includes('3 / 3 本已读取')")
            result['checks'].append(f'{width}px: visible-book allowlist, pending local preservation, explicit scope, unavailable-vs-empty and retry')
            search=page.get_by_role('searchbox',name='搜索全部个人摘记');search.fill('远山 LOCAL_PENDING')
            assert page.locator('.nh-card').count()==1
            page.locator('.nh-card .nh-preview-button').click()
            page.get_by_role('link',name='转到这里阅读',exact=True).wait_for()
            assert page.get_by_role('link',name='转到这里阅读',exact=True).get_attribute('href')=='#/read/book-a?at=2'
            assert page.locator('.nh-dialog mark').inner_text()=='甲'
            assert page.evaluate("JSON.stringify({...localStorage})===beforeStorage")
            page.screenshot(path=str(out/f'preview-{width}.png'),full_page=True)
            page.keyboard.press('Escape');page.wait_for_function("!document.querySelector('.nh-dialog')")
            assert page.locator('.nh-preview-button').evaluate('(e)=>e===document.activeElement')
            server.mismatch=True;page.locator('.nh-preview-button').click()
            page.get_by_text('保存的摘录与当前原文不一致',exact=False).wait_for()
            assert page.get_by_role('link',name='转到这里阅读',exact=True).count()==0
            assert '甲' in page.locator('.nh-preview-body').inner_text()
            page.get_by_role('button',name='关闭原文预览',exact=True).click()
            server.mismatch=False;server.delay=True;page.locator('.nh-preview-button').click()
            page.evaluate("document.querySelector('.nh-dialog').close()")
            page.wait_for_timeout(450)
            assert page.locator('.nh-dialog').count()==0
            assert page.evaluate("JSON.stringify({...localStorage})===beforeStorage")
            result['checks'].append(f'{width}px: validated UTF-16 preview and explicit jump link; mismatch refuses jump; Escape/native close cancel cleanly without changing notes or progress')
            search.fill('');page.get_by_role('combobox',name='按摘记类型筛选').select_option('bookmark')
            assert page.locator('.nh-card').count()==1
            page.get_by_role('combobox',name='按摘记类型筛选').select_option('')
            assert page.evaluate('document.documentElement.scrollWidth<=innerWidth+1')
            page.screenshot(path=str(out/f'hub-{width}.png'),full_page=True)
            page.evaluate('controller.abort()');context.close()
        # Initial authentication failure must reach the router, not masquerade as an empty notebook.
        server.auth=True
        context=browser.new_context(locale='zh-CN',);page=context.new_page();page.goto(origin+'/harness')
        name=page.evaluate("async()=>{const {openNotebookHub}=await import('/js/notebook-hub.js');try{await openNotebookHub(document.querySelector('#app'),{});return 'not-thrown'}catch(e){return e.constructor.name}}")
        assert name=='AuthError';context.close()
        result['checks'].append('initial authentication failure propagates to the router login flow')
        assert not result['page_errors'] and server.writes==0
        result['ok']=True;browser.close()
    finally:
        server.shutdown();(out/'validation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False))

if __name__=='__main__':main()
