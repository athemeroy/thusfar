"""Record marginalia decisions/prompts/cache behavior from Python 3.11 offline."""
import hashlib
import json
import sys
import tempfile
from difflib import SequenceMatcher
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
assert sys.version_info[:2] == (3, 11)
from server import marginalia as m

texts=['小林走进院子，轻轻地把门关上。他站在那里，一直没有说话。', '树影落在桌面上，他终于慢慢坐下，手指停在杯子旁边。', 'UNREAD SECRET 后文才揭露的秘密绝不能出现在材料中。']
blocks=[]; offset=0
for text in texts:
    blocks.append({'k':'p','t':text,'o':offset});offset+=len(text.encode('utf-16-le'))//2+1
book={'title':'离线批注测试','lang':'zh','genre':'novel','len':offset,'blocks':blocks,'chapters':[{'title':'第一章','b0':0,'b1':len(blocks),'o0':0,'o1':offset,'kind':'body'}]}
end=len(texts[0]);pos=blocks[1]['o']+len(texts[1])
log=[{'t':'person','p':0,'id':'p1','name':'小林'},{'t':'profile','p':1,'id':'p1','tagline':'刚刚回家的读者','bio':'他刚回到院子。'},{'t':'event','p':pos+1,'who':['p1'],'text':'UNREAD GRAPH SECRET'}]
base={'mode':'manual','pos':pos,'start':0,'end':end,'persona':'empathy'}
good={'comment':{'verdict':'ok','p':.9}}
flag={'comment':{'verdict':'flag','p':.1}}
cases=[
 ('manual_accepted',base,['这一声关门，比开口说话还让人在意。'],[good],None),
 ('manual_rewritten',base,['这里竟然藏着一个秘密房间。','这个轻轻关门的动作，让人也跟着安静下来。'],[flag,good],None),
 ('manual_withheld',base,['这里竟然藏着一个秘密房间。','后来他们还会在这里见面。'],[flag,flag],None),
 ('guard_outage',base,['这一声关门，比开口说话还让人在意。'],['error'],None),
 ('unusable_draft',base,['批注：JSON 系统提示'],[],None),
 ('auto_dedup',{'mode':'auto','pos':pos,'page_start':0,'page_end':end,'persona':'empathy'},['这一声关门，比开口说话还让人在意。','这一声关门，比开口说话还让人在意！','门关得这么轻，人却站得这么久。'],[{'empathy':{'verdict':'ok','p':.9},'wit':{'verdict':'ok','p':.8}}],None),
 ('auto_partial_failure',{'mode':'auto','pos':pos,'page_start':0,'page_end':end,'persona':'cold'},['error','这个小动作是否比他的沉默更有分量？','他一句话不说，我也有点不敢打扰。'],[{'detective':{'verdict':'ok','p':.8},'empathy':{'verdict':'flag','p':.2}}],None),
 ('cues',{'mode':'cues','purpose':'prefetch','pos':pos,'page_start':0,'page_end':pos},[],[],{'s1':{'choice':'feeling','probabilities':{'feeling':.8,'ordinary':.2}},'s2':{'choice':'ordinary','probabilities':{'ordinary':1}},'s3':{'choice':'clue','probabilities':{'clue':.7,'ordinary':.3}}}),
 ('invalid_mode',dict(base,mode='wrong'),[],[],None),('invalid_purpose',dict(base,purpose='prefetch'),[],[],None),('future_selection',dict(base,end=pos+1),[],[],None),('invalid_persona',dict(base,persona='wrong'),[],[],None),
]
out={'source_sha256':hashlib.sha256((ROOT/'server/marginalia.py').read_bytes()).hexdigest(),'book':book,'log':log,'frontier':pos-5,'revision':[123456789,101,7],'cases':[],'similarity':[]}
with tempfile.TemporaryDirectory() as td:
    root=Path(td);(root/'kg.json').write_text('{}')
    for name,data,replies,guards,answers in cases:
        calls=[];writes=[];chats=iter(replies);verdicts=iter(guards)
        content={'book.json':book,'kg.json':{'log':log},'status.json':{'frontier':pos-5},'marginalia.json':[]}
        def chat(model,messages,**kw):
            calls.append({'kind':'chat','model':model,'messages':messages,**kw});reply=next(chats)
            if reply=='error':raise RuntimeError('fixture draft outage')
            return reply,{}
        def guard(passage,earlier,items):
            calls.append({'kind':'guard','passage':passage,'earlier':earlier,'items':items});result=next(verdicts)
            if result=='error':raise RuntimeError('fixture judge outage')
            return result
        def judge(state,questions):calls.append({'kind':'judge','state':state,'questions':questions});return answers
        def write(path,value):content[path.name]=value;writes.append(value)
        with patch.object(m,'chat',side_effect=chat),patch.object(m,'guard_texts',side_effect=guard),patch.object(m,'jev',side_effect=judge),patch.object(m,'MODEL','fixture-reader'),patch.object(m,'AUTO_MODEL','fixture-auto'),patch.object(m.storage,'signature',return_value=tuple(out['revision'])),patch.object(m.time,'time',return_value=1234.5),patch.object(m.random,'choice',side_effect=lambda choices:choices[0]),patch.object(m.random,'sample',side_effect=lambda choices,k:list(choices[:k])):
            try:result=m.respond(root,data,lambda p:content.get(p.name),write)
            except Exception as exc:result={'error':{'type':type(exc).__name__,'message':str(exc)}}
            cached=m.respond(root,data,lambda p:content.get(p.name),write) if 'error' not in result else None
        out['cases'].append({'name':name,'input':data,'script':{'replies':replies,'guards':guards,'answers':answers},'calls':calls,'output':result,'cached':cached,'writes':writes})
for a,b in [('',''),('abc',''),('关上门，轻轻的。','关上门轻轻的'),('tide','diet'),('ab'*130,'ba'*130),('a'*220+'b','a'*220+'c'),('😀abc😀','abc😀def'),('这里没有那样的人物','这里没有那样的人物呀')]:out['similarity'].append({'a':a,'b':b,'ratio':SequenceMatcher(None,a,b).ratio()})
Path(__file__).with_name('fixtures').joinpath('oracles.json').write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
print(f'已记录 {len(cases)} 个批注场景和 {len(out["similarity"])} 个相似度基准，联网请求为 0')
