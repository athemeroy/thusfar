"""离线测量冻结书籍的解析边界和探针证据；不调用模型，不给模型正确率。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.parse import parse_txt, u16


def measure(root):
    rows = []
    for path in sorted((root / 'testsets').glob('*/*.txt')):
        raw = path.read_bytes()
        row = {'文件': str(path.relative_to(root)), '字节': len(raw),
               'sha256': hashlib.sha256(raw).hexdigest()}
        rows.append(row)
        if not raw.strip():
            row['状态'] = '空文件，排除'
            continue
        with tempfile.TemporaryDirectory() as directory:
            book = parse_txt(path, Path(directory))
        chapters, blocks = book['chapters'], book['blocks']
        offset, valid = 0, True
        for block in blocks:
            valid &= block['o'] == offset
            offset += u16(block['t']) + 1
        row.update(状态='已解析', 章节数=len(chapters), UTF16长度=book['len'],
                   偏移连续=bool(valid and offset == book['len']),
                   标题核对结果数=sum('spoil' in c for c in chapters))
        probe_path = path.parent / 'probes.json'
        if not probe_path.exists():
            continue
        probes = json.loads(probe_path.read_text())['probes']
        evidence = []
        for probe in probes:
            item = {'id': probe['id'], '标注章节': probe['chapter']}
            evidence.append(item)
            if not probe.get('verify'):
                item['状态'] = '无正则证据字段，需逐条语义核对'
                continue
            # 中文冻结集回目顺序；开始/前言不计入回数。
            numbered = [c for c in chapters if re.match(r'^第[零〇一二三四五六七八九十百千万两0-9]+[回章]', c['title'])]
            if len(numbered) < probe['chapter']:
                item['状态'] = '标注章节不存在'
                continue
            chapter = numbered[probe['chapter'] - 1]
            content = '\n'.join(b['t'] for b in blocks[chapter['b0']:chapter['b1']])
            match = re.search(probe['verify'], content)
            item.update(回目=chapter['title'], 状态='证据命中' if match else '未命中',
                        证据=content[max(0, match.start()-50):match.end()+50] if match else '')
        row['探针证据'] = evidence
    return {'说明': '仅测原文与解析；证据命中不证明首次成立，不代表模型质量或人工正确率。',
            '模型调用数': 0, '模型一致率': None, '人工正确率': None, '书籍': rows}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(measure(Path(__file__).resolve().parents[1]), ensure_ascii=False, indent=2) + '\n')
