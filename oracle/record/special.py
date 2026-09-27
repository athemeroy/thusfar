"""Record helpers requiring explicit, typed fixtures beyond the general tracer.

The general function tracer cannot encode a returned closure, a callback argument, or
Runner's live lock. It also misses changes to mutable arguments when the return value
is None. Integration tests pass variable file revisions and wall-clock fields into
several otherwise deterministic helpers. These cases record fixed state and observable
calls instead. Every fixture is synthetic; no external service is used.
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
import tempfile
import threading
import unicodedata
from pathlib import Path

from .common import canonical, encode, known_secrets, require_reference_runtime
from .functions import LoopbackOnly

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / 'oracle/goldens/special'
SOURCES = ('pipeline/run.py', 'pipeline/parse.py', 'pipeline/kg.py', 'pipeline/lang.py',
           'server/manual_entities.py', 'server/marginalia.py',
           'server/notebook.py', 'server/storage.py',
           'oracle/record/common.py', 'oracle/record/special.py')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def case(function: str, label: str, inputs: dict, call, secrets: tuple[str, ...],
         *, error: str | None = None) -> dict:
    """Record a successful result or one exact, expected Python rejection."""
    frozen_input = encode(inputs, secrets)
    try:
        value = call()
    except ValueError as exc:
        if error is None or str(exc) != error:
            raise
        value = exc
    else:
        if error is not None:
            raise AssertionError(f'{function}/{label} no longer rejects: {error}')
    return {'schema': 1, 'function': function, 'case': label,
            'input': frozen_input, 'output': encode(value, secrets)}


def state_case(function: str, label: str, arguments: dict, call,
               secrets: tuple[str, ...], *, aliases=None) -> dict:
    """Record argument state on both sides of a call, including its return value.

    ``arguments`` contains the actual objects passed to ``call``. Encoding before the
    call makes a detached snapshot, so mutations cannot rewrite the input golden.
    ``aliases`` observes identities that JSON values cannot represent.
    """
    before = encode(arguments, secrets)
    value = call()
    row = {'schema': 1, 'function': function, 'case': label,
           'before': before, 'after': encode(arguments, secrets),
           'return': encode(value, secrets)}
    if aliases is not None:
        row['aliases'] = encode(aliases(value), secrets)
    return row


def rows() -> dict[str, list[dict]]:
    from pipeline.kg import KG
    from pipeline.parse import classify, finish
    from pipeline.run import Runner, attr_facts, settle_rewrites
    from server import manual_entities, marginalia, notebook

    secrets = known_secrets()
    book = {'lang': 'zh', 'blocks': []}
    result: dict[str, list[dict]] = {}

    kg = KG(book)
    kg.people['P1'] = {'name': '贾宝玉', 'tagline': '荣府公子', 'intro': '初次登场'}
    runner = Runner.__new__(Runner)
    runner.kg = kg
    data = {'new_people': [{'ref': 'N1', 'name': '林黛玉', 'intro': '初到荣府'}]}
    plan = {'refmap': {'N1': 'P2'}}
    ids = ['P1', 'P2']
    description_input = encode({
        'book': book, 'kg_people': kg.people, 'data': data, 'plan': plan,
        'returned_closure_calls': ids,
    }, secrets)
    describe = runner._describe_factory(data, plan)
    description_output = encode([{'pid': pid, 'value': describe(pid)} for pid in ids], secrets)
    result['describe_factory.jsonl'] = [{
        'schema': 1, 'function': 'pipeline.run.Runner._describe_factory',
        'case': 'known_and_new_person', 'input': description_input,
        'output': description_output,
    }]

    people = {'P1': ('贾宝玉', '荣府公子'), 'P2': ('林黛玉', '寄居荣府')}
    attributes = {'attrs': [
        {'who': 'P1', 'key': '住处', 'value': '荣府'},
        {'who': 'P1', 'key': '空值', 'value': ''},
        {'who': 'P2', 'key': '籍贯', 'value': '姑苏'},
    ]}

    def who_of(pid: str) -> tuple[str, str]:
        return people[pid]

    result['attr_facts.jsonl'] = [{
        'schema': 1, 'function': 'pipeline.run.attr_facts',
        'case': 'callback_map_and_empty_attribute',
        'input': encode({'data': attributes, 'who_of_map': people}, secrets),
        'output': encode(attr_facts(attributes, who_of), secrets),
    }]

    saga_log = [
        {'t': 'saga', 'p': 20, 'text': '第一段前情'},
        {'t': 'event', 'p': 30, 'text': '中途事件', 'who': []},
        {'t': 'saga', 'p': 40, 'text': '第二段前情'},
    ]
    runner.kg.log = saga_log
    runner.lock = threading.RLock()
    calls = [{'end_pos': pos, 'fallback': '无前情'} for pos in (20, 40, 41)]
    saga_input = encode({'kg_log': saga_log, 'lock_kind': 'RLock', 'calls': calls}, secrets)
    saga_output = encode([
        {'end_pos': call['end_pos'], 'value': runner.earlier_saga(**call)}
        for call in calls
    ], secrets)
    result['earlier_saga.jsonl'] = [{
        'schema': 1, 'function': 'pipeline.run.Runner.earlier_saga',
        'case': 'strict_cutoff_and_fallback',
        'input': saga_input, 'output': saga_output,
    }]

    manual_book = {'len': 30, 'blocks': [{'k': 'p', 'o': 0, 't': '😀尼尔遇见黑月。'}]}
    manual_item = {
        'id': '12345678-abcd', 'kind': 'person', 'name': ' 尼尔 ',
        'knowledge_cutoff': 20, 'note': ' 后来才知道 ',
        'created': 1730000000.0, 'updated': 1730000030.0,
    }
    result['manual_base.jsonl'] = [
        case('server.manual_entities._base', 'trimmed_valid_item',
             {'item': manual_item, 'book': manual_book},
             lambda: manual_entities._base(manual_item, manual_book), secrets),
        case('server.manual_entities._base', 'invalid_id',
             {'item': {**manual_item, 'id': 'short'}, 'book': manual_book},
             lambda: manual_entities._base({**manual_item, 'id': 'short'}, manual_book),
             secrets, error='手动条目编号无效'),
    ]

    stored_item = {
        'id': '12345678-abcd', 'kind': 'person', 'name': '尼尔',
        'knowledge_cutoff': 20, 'source_start': 2,
        'versions': [{'p': 10, 'note': '已出现'}, {'p': 20, 'note': '后来才知道'}],
        'deleted': False, 'revision': 2, 'operation': 'cccccccc-dddd',
        'created': 1730000000.0, 'updated': 1730000030.0,
    }
    result['manual_rows.jsonl'] = [
        case('server.manual_entities.rows', 'versioned_visible_entry',
             {'items': [stored_item]}, lambda: manual_entities.rows([stored_item]), secrets),
        case('server.manual_entities.rows', 'deleted_entry_hidden',
             {'items': [{**stored_item, 'deleted': True}]},
             lambda: manual_entities.rows([{**stored_item, 'deleted': True}]), secrets),
    ]

    overlay_items = [
        {'id': '12345678-abcd', 'name': '尼尔', 'deleted': False,
         'created': 1730000000.0, 'updated': 1730000030.0},
        {'id': 'abcdefgh-1234', 'name': '黑月', 'deleted': False,
         'created': 1730000000.0, 'updated': 1730000030.0},
        {'id': 'deleted-1234', 'name': '遇见', 'deleted': True,
         'created': 1730000000.0, 'updated': 1730000030.0},
    ]
    generated_mentions = [[2, 4, 'P1']]
    result['manual_mentions.jsonl'] = [
        case('server.manual_entities.mentions', 'generated_mention_wins_overlap',
             {'blocks': manual_book['blocks'], 'items': overlay_items,
              'existing': generated_mentions},
             lambda: manual_entities.mentions(manual_book['blocks'], overlay_items,
                                              generated_mentions), secrets),
        case('server.manual_entities.mentions', 'all_manual_names_deleted',
             {'blocks': manual_book['blocks'],
              'items': [{**item, 'deleted': True} for item in overlay_items],
              'existing': generated_mentions},
             lambda: manual_entities.mentions(
                 manual_book['blocks'], [{**item, 'deleted': True} for item in overlay_items],
                 generated_mentions), secrets),
    ]

    result['manual_restore.jsonl'] = [
        case('server.manual_entities.restore', 'fixed_timestamps_and_anchor',
             {'items': [stored_item], 'book': manual_book},
             lambda: manual_entities.restore([stored_item], manual_book), secrets),
        case('server.manual_entities.restore', 'changed_source_anchor',
             {'items': [{**stored_item, 'source_start': 3}], 'book': manual_book},
             lambda: manual_entities.restore([{**stored_item, 'source_start': 3}], manual_book),
             secrets, error='手动条目原文位置无效'),
    ]

    graph_revision = (1730000000123456789, 481, 7001)
    manual_payload = {
        'mode': 'manual', 'pos': 20, 'persona': 'cold',
        'knowledge_frontier': 18, 'graph_revision': graph_revision,
        'start': 2, 'end': 4, 'quote': '尼尔',
    }
    cues_payload = {
        'mode': 'cues', 'pos': 20, 'persona': 'auto',
        'knowledge_frontier': 18, 'graph_revision': graph_revision,
        'page_start': 0, 'page_end': 20,
    }
    result['marginalia_key.jsonl'] = [
        case('server.marginalia._key', 'manual_fixed_graph_revision',
             {'payload': manual_payload}, lambda: marginalia._key(manual_payload), secrets),
        case('server.marginalia._key', 'cues_version_fixed_graph_revision',
             {'payload': cues_payload}, lambda: marginalia._key(cues_payload), secrets),
        case('server.marginalia._key', 'changed_inode_changes_key',
             {'payload': {**manual_payload, 'graph_revision': graph_revision[:2] + (7002,)}},
             lambda: marginalia._key({**manual_payload,
                                      'graph_revision': graph_revision[:2] + (7002,)}), secrets),
    ]

    notebook_book = {'len': 30, 'blocks': [{'k': 'p', 'o': 0, 't': '😀Alice met Bob.'}]}
    note = {
        'id': 'note-test-0001', 'kind': 'note', 'start': 2, 'end': 7,
        'quote': 'Alice', 'text': 'A first thought', 'knowledge_cutoff': 10,
        'created': 1730000000.0, 'updated': 1730000030.0,
    }
    result['notebook_validate.jsonl'] = [
        case('server.notebook.validate', 'source_exact_after_supplementary_char',
             {'item': note, 'book': notebook_book},
             lambda: notebook.validate(note, notebook_book), secrets),
        case('server.notebook.validate', 'mismatched_quote_rejected',
             {'item': {**note, 'quote': 'Alicé'}, 'book': notebook_book},
             lambda: notebook.validate({**note, 'quote': 'Alicé'}, notebook_book),
             secrets, error='摘录与原文不一致，未保存到错误位置'),
        case('server.notebook.validate', 'surrogate_split_rejected',
             {'item': {**note, 'start': 1, 'quote': 'Alice'}, 'book': notebook_book},
             lambda: notebook.validate({**note, 'start': 1, 'quote': 'Alice'}, notebook_book),
             secrets, error='摘录位置已变化，请重新选择原文'),
    ]

    # These functions return None (or a result that aliases an input) while changing
    # their arguments. A return-only recording would silently lose that contract.
    # ``settle_rewrites`` reads only guard/data; no wall-clock timing field is needed.
    rollback = {
        'data': {'profiles': [{'who': 'P1', 'tagline': '改写称号', 'bio': '改写介绍'}]},
        'guard': {'checks': {'P1': {'verdict': 'rewritten', 'verified': False,
                                   'first': 0.8, 'jev': 0.7}},
                  'rewrites': {'P1': {'before': {'tagline': '原称号', 'bio': '原介绍'}}}},
    }
    threshold = {
        'data': {'profiles': [{'who': 'P1', 'tagline': '改写称号', 'bio': '改写介绍'}]},
        'guard': {'checks': {'P1': {'verdict': 'rewritten', 'verified': False,
                                   'first': 0.3, 'jev': 0.5}},
                  'rewrites': {'P1': {'before': {'tagline': '原称号', 'bio': '原介绍'}}}},
    }
    verified = {
        'data': {'profiles': [{'who': 'P1', 'tagline': '改写称号', 'bio': '改写介绍'}]},
        'guard': {'checks': {'P1': {'verdict': 'rewritten', 'verified': True,
                                   'after_verdict': 'ok', 'first': 0.8, 'jev': 0.1}},
                  'rewrites': {'P1': {'before': {'tagline': '原称号', 'bio': '原介绍'}}}},
    }
    result['settle_rewrites_state.jsonl'] = [
        state_case('pipeline.run.settle_rewrites', label, {'rec': rec},
                   lambda rec=rec: settle_rewrites(rec), secrets)
        for label, rec in (
            ('below_jev_threshold_reverts_profile_and_verdict', rollback),
            ('equal_jev_threshold_keeps_rewrite', threshold),
            ('verified_ok_keeps_low_jev_rewrite', verified),
        )
    ]

    chapters = [
        {'title': '前言', 'o0': 0, 'o1': 500},
        {'title': '短章', 'o0': 500, 'o1': 799},
        {'title': '第一章', 'o0': 799, 'o1': 1099},
        {'title': '附录', 'o0': 1099, 'o1': 1399},
        {'title': '致谢', 'o0': 1399, 'o1': 1699},
    ]
    middle_back = [
        {'title': '第一章', 'o0': 0, 'o1': 300},
        {'title': '附录', 'o0': 300, 'o1': 600},
        {'title': '第二章', 'o0': 600, 'o1': 900},
    ]
    classify_blocks = [{'t': '原文', 'o': 0}]
    result['classify_state.jsonl'] = [
        state_case('pipeline.parse.classify', label,
                   {'chapters': cs, 'blocks': classify_blocks},
                   lambda cs=cs: classify(cs, classify_blocks), secrets)
        for label, cs in (
            ('front_size_299_body_size_300_and_trailing_back', chapters),
            ('back_word_in_middle_remains_body', middle_back),
        )
    ]

    blocks = [
        {'t': '😀', 'cls': 'lead', 'ids': ['old'],
         'fn': [[0, 'note-a'], [0, 'missing']]},
        {'t': '甲' * 300, 'fn': []},
    ]
    starts = [(1, '第一章', 0)]
    notes = {'note-a': '脚注原文', 'unused': '未引用'}
    arguments = {'blocks': blocks, 'starts': starts, 'notes': notes,
                 'title': '测试书', 'author': '测试作者'}
    result['finish_state.jsonl'] = [
        state_case('pipeline.parse.finish', 'utf16_offset_cover_cleanup_and_footnote',
                   arguments,
                   lambda: finish(blocks, starts, notes, '测试书', '测试作者'),
                   secrets,
                   aliases=lambda value: {
                       'return_blocks_is_input_blocks': value['blocks'] is blocks,
                       'return_first_block_is_input_first_block': value['blocks'][0] is blocks[0],
                   }),
    ]
    return result


def one_pass(out: Path) -> None:
    require_reference_runtime()
    if out.exists():
        raise FileExistsError(f'output exists: {out}')
    out.mkdir(parents=True)
    with LoopbackOnly():
        cases = rows()
    for name, values in sorted(cases.items()):
        (out / name).write_text(''.join(canonical(row) + '\n' for row in values),
                                encoding='utf-8')


def files(root: Path) -> dict[str, bytes]:
    return {str(path.relative_to(root)): path.read_bytes()
            for path in sorted(root.rglob('*')) if path.is_file()}


def expected_files() -> dict[str, bytes]:
    require_reference_runtime()
    with tempfile.TemporaryDirectory(prefix='thusfar-special-') as directory:
        captures = []
        for index in range(2):
            out = Path(directory) / str(index)
            subprocess.run([sys.executable, '-m', 'oracle.record.special', '--one-pass', str(out)],
                           check=True, cwd=ROOT)
            captures.append(files(out))
        if captures[0] != captures[1]:
            raise RuntimeError('two independent special-function recordings differ byte-for-byte')
        actual = captures[0]
    provenance = {
        'schema': 1,
        'source': 'checked-out Thusfar Python source; handwritten synthetic direct calls; no model or network',
        'python': sys.version.split()[0],
        'unicode': unicodedata.unidata_version,
        'passes': 2,
        'sources_sha256': {name: sha256((ROOT / name).read_bytes()) for name in SOURCES},
        'goldens_sha256': {name: sha256(data) for name, data in sorted(actual.items())},
    }
    actual['provenance.json'] = (canonical(provenance) + '\n').encode('utf-8')
    return actual


def generate(out: Path = DEFAULT_OUT, *, verify: bool = False) -> dict[str, bytes]:
    actual = expected_files()
    if out.exists():
        existing = files(out)
        if actual != existing:
            changed = sorted(set(actual) ^ set(existing) | {
                name for name in actual.keys() & existing.keys() if actual[name] != existing[name]
            })
            raise RuntimeError(f'existing special goldens differ: {", ".join(changed)}')
    elif verify:
        raise FileNotFoundError(f'special goldens do not exist: {out}')
    else:
        out.mkdir(parents=True)
        for name, data in sorted(actual.items()):
            (out / name).write_bytes(data)
    return actual


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--one-pass', type=Path)
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.one_pass is not None:
        one_pass(args.one_pass)
    else:
        actual = generate(args.out, verify=args.verify)
        print(f'{len(actual) - 1} special-function golden files match two Python 3.11 passes')


if __name__ == '__main__':
    main()
