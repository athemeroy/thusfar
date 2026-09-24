"""Synthetic reading-home acceptance; no real books, models, or external calls."""
import argparse, functools, http.server, json, threading, sys, time
from pathlib import Path
from urllib.parse import urlparse,unquote
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(); parser.add_argument('--out-dir', default='/tmp/yedu-library-browser'); args=parser.parse_args()
OUT=Path(args.out_dir); OUT.mkdir(parents=True,exist_ok=True)
BOOKS=[{'id':'old','title':'清晨的书','author':'作者甲','len':12000,'added':10,'progress':{'pos':3000,'pct':25,'t':200},'status':{'state':'done','people':3}}, {'id':'latest','title':'The Long Journey','author':'Author Two','len':24000,'added':20,'progress':{'pos':6000,'pct':25,'t':100},'status':{'state':'done','quality':{'state':'pending'}}}, {'id':'finished','title':'读完的一本书','author':'作者乙','len':18000,'added':30,'progress':{'pos':17900,'pct':100,'t':900},'offline':True,'status':{'state':'done'}}, {'id':'unread','title':'未开始的故事','author':'作者甲','len':34000,'added':40,'status':{'state':'idle'},'est':{'minutes':5,'low':0,'high':0,'model':'fixture'}}, {'id':'running','title':'正在整理的书','author':'作者丁','len':30000,'added':50,'status':{'state':'running','done':2,'total':10}}]
CALLS=[]
DOWNLOAD_FAIL=True
class Handler(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*_): pass
 def data(self,data,status=200):
  raw=json.dumps(data,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def do_GET(self):
  global DOWNLOAD_FAIL
  path=urlparse(self.path).path
  if path=='/api/books': return self.data(BOOKS)
  if path=='/api/me': return self.data({'ok':True})
  if path=='/api/settings': return self.data({'base_url':'https://example.test/v1','model':'fixture-model','api_key_set':True,'api_key_last4':'1234'})
  if path=='/api/books/old/offline-manifest':
   chapter={'title':'原创测试章节','o0':0,'o1':12000,'kind':'body','spoil':False}
   return self.data({'version':'library-fixture-v1','book':{**BOOKS[0],'version':'library-text-v1','chapters':[chapter]}, 'chapters':[{'n':0,'url':'/api/books/old/chapters/0','images':[]}], 'assets':[], 'graph':{'url':'/api/books/old/kg?from=-1&to=12000','to':12000}, 'state':'done','frontier':12000})
  if path=='/api/books/old/chapters/0':
   if DOWNLOAD_FAIL:
    DOWNLOAD_FAIL=False
    return self.data({'error':'synthetic interrupted download'},503)
   return self.data({'n':0,'title':'原创测试章节','o0':0,'o1':12000,'blocks':[{'k':'p','t':'原创的离线阅读夹具。','o':0}],'mentions':[],'notes':{}})
  if path=='/api/books/old/kg': return self.data({'from':-1,'to':12000,'frontier':12000,'state':'done','records':[]})
  if path.startswith('/api/'): return self.data({'error':'Synthetic fixture endpoint unavailable'},404)
  return super().do_GET()
 def do_POST(self):
  CALLS.append(self.path); raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
  if self.path=='/api/books':
   name=unquote(self.headers.get('X-Filename','fixture.txt'))
   if name.startswith('bad'): return self.data({'error':'测试文件无法解析'},400)
   time.sleep(.12)
   b={'id':'imported','title':'导入的新书','author':'新作者','len':6000,'status':{'state':'idle'}}
   if not any(row['id']==b['id'] for row in BOOKS): BOOKS.append(b)
   return self.data(b)
  if self.path.endswith('/process'): return self.data({'ok':True})
  return self.data({'ok':True})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(ROOT/'web')))
threading.Thread(target=server.serve_forever,daemon=True).start(); origin=f'http://127.0.0.1:{server.server_address[1]}'
result={'checks':[],'errors':[],'isolation':'loopback synthetic library; external requests denied'}
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(headless=True,args=['--no-proxy-server'])
  context=browser.new_context(locale='zh-CN',viewport={'width':390,'height':844},service_workers='block')
  context.route('**/*',lambda route:route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
  page=context.new_page();page.set_default_timeout(10000);page.on('pageerror',lambda e:result['errors'].append(str(e)))
  page.goto(origin,wait_until='networkidle')
  page.evaluate("localStorage.setItem('resume:latest', JSON.stringify({pos:2000,pct:8,updatedAt:300000,dirty:true})); localStorage.setItem('library-imports-v1',JSON.stringify([{key:'interrupted',name:'previous.epub',state:'uploading'}]));")
  page.reload(wait_until='networkidle');page.locator('.library-card').first.wait_for()
  assert page.locator('.library-resume h2').inner_text()=='The Long Journey'
  assert '本机进度待保存' in page.locator('.library-resume').inner_text()
  assert '上次导入未收到完成确认' in page.locator('.library-imports').inner_text()
  result['checks'].append('reading home resumes latest dirty local progress, not more-recent completed book; interrupted imports recover honestly')
  page.get_by_role('searchbox',name='搜索书名或作者').fill('作者甲'); assert page.locator('.library-card').count()==2
  page.get_by_role('button',name='未读 2',exact=True).click();assert page.locator('.library-card').count()==1
  page.get_by_role('button',name='列表',exact=True).click(); assert page.locator('.library-books').get_attribute('data-layout')=='list'
  page.reload(wait_until='networkidle'); assert page.get_by_role('searchbox').input_value()=='作者甲'; assert page.locator('.library-card').count()==1
  result['checks'].append('title/author search composes with reading filter and list layout, retained after reload')
  page.get_by_role('button',name='清空搜索').click();page.get_by_role('button',name='全部 5',exact=True).click()
  page.get_by_role('button',name='封面',exact=True).click()
  page.get_by_label('书籍排序').select_option('title')
  menu=page.get_by_role('button',name='《The Long Journey》书籍菜单');menu.click()
  assert page.locator('dialog[open]').count()==1
  assert page.get_by_role('button',name='重试待核对资料',exact=False).count()==1
  assert not any(path.endswith('/process') for path in CALLS)
  # Escape closes and restores focus to the originating book action.
  page.keyboard.press('Escape');assert page.locator('dialog[open]').count()==0;assert menu.evaluate('(el)=>el===document.activeElement')
  result['checks'].append('book actions separate reading/download/export/explicit model retry; modal Escape restores keyboard focus')
  page.get_by_role('button',name='《未开始的故事》书籍菜单').click()
  page.on('dialog',lambda d:d.dismiss());page.get_by_role('button',name='开始整理人物',exact=False).click(); assert not any(path.endswith('/process') for path in CALLS)
  page.get_by_role('button',name='关闭书籍菜单').click()
  result['checks'].append('canceling explicit AI confirmation sends zero process requests')
  # Focus survives status polling while query input text remains intact.
  page.get_by_role('searchbox').fill('作者');page.get_by_role('searchbox').focus();page.evaluate("window.dispatchEvent(new Event('online'))");page.wait_for_timeout(300)
  assert page.get_by_role('searchbox').evaluate('(el)=>el===document.activeElement');assert page.get_by_role('searchbox').input_value()=='作者'
  result['checks'].append('background refresh preserves active search input/focus')
  page.get_by_role('button',name='清空搜索').click()
  page.locator('input[type=file]').set_input_files([{'name':'good.txt','mimeType':'text/plain','buffer':b'fixture good'},{'name':'bad.txt','mimeType':'text/plain','buffer':b'fixture bad'}])
  page.locator('.library-import-row.is-done').wait_for();page.locator('.library-import-row.is-failed').wait_for()
  assert page.locator('.library-import-row.is-done').get_by_role('link',name='打开阅读').count()==1
  assert page.locator('.library-import-row.is-failed').get_by_role('button',name='重试',exact=True).count()==1
  assert page.locator('[data-book-id=imported]').count()==1
  page.reload(wait_until='networkidle');assert page.locator('.library-import-row.is-done').count()==1;assert page.locator('.library-import-row.is-failed').get_by_role('button',name='重新选文件').count()==1
  result['checks'].append('mixed upload success/failure remains per-file and durable after reload; successful book opens and failed file can be reselected')
  page.evaluate('window.scrollTo(0,0)');page.screenshot(path=str(OUT/'library-390.png'),full_page=True)
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth'), 'mobile horizontal overflow'
  page.set_viewport_size({'width':1440,'height':1000});page.screenshot(path=str(OUT/'library-1440.png'),full_page=True)
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth'), 'desktop horizontal overflow'
  page.set_viewport_size({'width':320,'height':720});assert page.evaluate('document.documentElement.scrollWidth<=innerWidth'), '320px horizontal overflow'
  result['checks'].append('responsive layouts stay within 320/390/1440px viewport')
  # Exercise the real service worker with an interrupted download and retry.
  offline_context=browser.new_context(locale='zh-CN',viewport={'width':390,'height':844})
  offline_context.route('**/*',lambda route:route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
  offline_page=offline_context.new_page();offline_page.set_default_timeout(15000)
  offline_page.on('pageerror',lambda e:result['errors'].append(str(e)))
  offline_page.goto(origin,wait_until='networkidle')
  offline_page.evaluate('navigator.serviceWorker.ready')
  offline_page.wait_for_function('!!navigator.serviceWorker.controller')
  offline_page.get_by_role('button',name='《清晨的书》书籍菜单').click()
  offline_page.get_by_role('button',name='下载到本机',exact=False).click()
  offline_page.wait_for_function("document.querySelector('.library-action-message')?.textContent.includes('503')")
  assert offline_page.locator('[data-book-id=old] .library-offline').count()==0
  offline_page.get_by_role('button',name='下载到本机',exact=False).click()
  offline_page.wait_for_function("document.querySelector('.library-action-message')?.textContent.includes('已下载到本机')")
  offline_page.get_by_role('button',name='关闭书籍菜单').click()
  # The fixture marks another book downloaded in its initial API response; the worker
  # correctly replaces that claim with the actual complete local snapshot index.
  offline_page.get_by_role('button',name='已下载 1',exact=True).click()
  assert offline_page.locator('.library-card').count()==1
  offline_context.set_offline(True)
  offline_page.reload(wait_until='domcontentloaded');offline_page.locator('[data-book-id=old]').wait_for()
  assert offline_page.locator('.library-card').count()==1
  assert '当前离线' in offline_page.locator('.library-notice').inner_text()
  result['checks'].append('failed download is not marked available; retry publishes complete snapshot and downloaded-only home reopens offline')
  standalone_context=browser.new_context(locale='zh-CN',viewport={'width':390,'height':844},service_workers='block',user_agent='Mozilla/5.0 YeduApp/1.7.0 YeduStandalone/1')
  standalone_context.route('**/*',lambda route:route.continue_() if route.request.url.startswith(origin+'/') else route.abort())
  standalone_page=standalone_context.new_page();standalone_page.set_default_timeout(10000)
  standalone_page.on('pageerror',lambda e:result['errors'].append(str(e)))
  standalone_page.add_init_script("localStorage.setItem('library-view-v1', JSON.stringify({view:'grid',sort:'title'}))")
  standalone_page.goto(origin,wait_until='networkidle');standalone_page.locator('.library-card').first.wait_for()
  assert standalone_page.title()=='页读'
  assert standalone_page.locator('.library-books').get_attribute('data-layout')=='list'
  assert standalone_page.get_by_label('书籍排序').input_value()=='title'
  assert standalone_page.locator('.library-card').first.bounding_box()['y']<700
  assert standalone_page.get_by_role('navigation',name='书房导航').get_by_role('link').count()==3
  assert standalone_page.evaluate('document.documentElement.scrollWidth<=innerWidth')
  standalone_page.screenshot(path=str(OUT/'standalone-home-390.png'))
  standalone_page.get_by_role('button',name='《未开始的故事》书籍菜单').click()
  assert standalone_page.locator('.library-ai-heading').bounding_box()['y'] < standalone_page.get_by_role('link',name='我的摘记',exact=False).bounding_box()['y']
  standalone_page.screenshot(path=str(OUT/'standalone-book-menu-390.png'))
  standalone_page.get_by_role('button',name='关闭书籍菜单').click()
  standalone_page.get_by_role('link',name='设置').click()
  assert standalone_page.locator('.model-settings h1').inner_text()=='模型设置'
  assert standalone_page.get_by_text('已保存密钥，末尾 1234').count()==1
  assert standalone_page.locator('input[aria-label="API 密钥"]').input_value()==''
  standalone_page.screenshot(path=str(OUT/'standalone-settings-390.png'))
  result['checks'].append('standalone brand, compact list, first-screen book, prioritized AI action, and private-key settings render on a phone viewport')
  standalone_context.close()
  assert not result['errors'],result['errors']
  browser.close()
finally:
 server.shutdown();(OUT/'acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
