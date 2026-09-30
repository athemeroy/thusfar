"""Temporal graph contract shared with web/js/kg.js through offline fixtures."""
from collections import defaultdict


GENERIC = set('父亲 母亲 爸爸 妈妈 爹 娘 儿子 女儿 丈夫 妻子 太太 夫人 先生 老爷 小姐 姑娘 少女 女孩 少年 男孩 青年 少爷 医生 大夫 校长 老师 神父 堂长 老板 老板娘 仆人 女仆 老头子 老太太 老头 孩子 哥哥 姐姐 弟弟 妹妹 叔叔 伯父 舅舅 姑妈 姨妈 祖父 祖母 爷爷 奶奶 外公 外婆 公公 婆婆 岳父 岳母 丈人 主人 客人 新娘 新郎 新娘子 新夫人 寡妇 邻居 朋友 同学 学生 病人 大人 老人 年轻人 女人 男人 闺女 媳妇 老婆 老公 东家 女婿 未婚女婿 未婚妻 未婚夫 儿媳'.split())


def fold(log, pos):
    import re
    people, merges, relations, events, recaps = {}, {}, [], [], []
    early = defaultdict(list)
    saga = ''

    def apply(r):
        kind = r['t']
        pid = r.get('id')
        if kind in ('name', 'alias', 'profile', 'attr', 'imp') and pid not in people:
            early[pid].append(r)
            return
        if kind == 'person':
            people[pid] = {'id': pid, 'name': r['name'], 'aliases': [], 'tagline': r.get('intro', ''),
                           'bio': '', 'attrs': {}, 'attr_history': defaultdict(list),
                           'imp': r.get('imp', 1), 'n': 0, 'events': []}
            for held in early.pop(pid, []):
                apply(held)
        elif kind == 'name':
            if people[pid]['name'] != r['name']:
                people[pid]['aliases'].append(people[pid]['name'])
                people[pid]['name'] = r['name']
        elif kind == 'alias':
            people[pid]['aliases'].append(r['alias'])
        elif kind == 'merge':
            merges[r['from']] = r['into']
        elif kind == 'profile':
            people[pid]['tagline'] = r.get('tagline') or people[pid]['tagline']
            people[pid]['bio'] = r.get('bio') or people[pid]['bio']
        elif kind == 'attr':
            people[pid]['attr_history'][r['key']].append({'v': r['value'], 'p': r['p']})
        elif kind == 'rel':
            relations.append(r)
        elif kind == 'event':
            events.append(r)
        elif kind == 'imp':
            people[pid]['imp'] = r['imp']
        elif kind == 'cnt':
            for who, count in r['c'].items():
                if who in people:
                    people[who]['n'] += count
        elif kind == 'recap':
            recaps.append(r)

    for row in log:
        if row['p'] > pos:
            break
        if row['t'] == 'saga':
            saga = row['text']
        else:
            apply(row)

    def canon(pid):
        seen = set()
        while pid in merges and pid not in seen:
            seen.add(pid)
            pid = merges[pid]
        return pid

    for src_id in merges:
        target_id = canon(src_id)
        if src_id == target_id or src_id not in people or target_id not in people:
            continue
        src, target = people.pop(src_id), people[target_id]
        if target['name'] in GENERIC and src['name'] not in GENERIC:
            target['name'] = src['name']
        target['aliases'].extend([src['name']] + src['aliases'])
        target['n'] += src['n']
        if not target['bio']:
            target['bio'] = src['bio']
        for key, values in src['attr_history'].items():
            target['attr_history'][key] = values + target['attr_history'][key]
    names = {p['name']: p['id'] for p in people.values()}
    for person in people.values():
        person['aliases'] = list(dict.fromkeys(x for x in person['aliases'] if x and x != person['name']
            and x not in GENERIC and re.sub(r'^[他她的老小未]+', '', x) not in GENERIC
            and not re.search(r'的|夫妇|夫妻|们|一家|俩', x)
            and not (x in names and names[x] != person['id'])))
        for key, values in person['attr_history'].items():
            values.sort(key=lambda x: x['p'])
            person['attrs'][key] = values[-1]['v']
    for event in events:
        for pid in {canon(x) for x in event['who']}:
            if pid in people:
                people[pid]['events'].append(event)
    rels = {}
    for record in relations:
        a, b = canon(record['a']), canon(record['b'])
        if a == b or a not in people or b not in people:
            continue
        key = '|'.join(sorted((a, b))) + ('|' + record['family'] if record.get('family') else '')
        previous = rels.get(key)
        row = dict(record, a=a, b=b)
        if a > b:
            row.update(a=b, b=a, a_is=record.get('b_is', ''), b_is=record.get('a_is', ''))
        if previous:
            reverse = previous['a'] != row['a']
            for field, oldfield in [('a_is', 'b_is' if reverse else 'a_is'),
                                    ('b_is', 'a_is' if reverse else 'b_is'), ('desc', 'desc'), ('status', 'status')]:
                row[field] = row.get(field) or previous.get(oldfield, '')
            row['history'] = previous.get('history', []) + [{k: v for k, v in previous.items() if k != 'history'}]
        else:
            row['history'] = []
        rels[key] = row
    return {'people': people, 'rels': rels, 'events': events, 'saga': saga, 'recaps': recaps}
