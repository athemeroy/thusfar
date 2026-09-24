"""Offline HTTP and lifecycle regressions; fixtures only, external models forbidden."""
import base64
import concurrent.futures
import copy
import gzip
import hashlib
import http.client
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from server import app, ask, jobs, storage
from server.temporal import fold


def book_fixture(image=False):
    blocks = [{'k': 'p', 't': 'Alice came.', 'o': 0, 'fn': []}]
    if image:
        blocks.append({'k': 'img', 't': '', 'o': 11, 'src': 'cover.png'})
    return {'title': 'Fixture', 'author': 'Tester', 'len': 12, 'lang': 'en', 'notes': {},
            'blocks': blocks, 'cover': 'cover.png' if image else None,
            'chapters': [{'title': 'One', 'b0': 0, 'b1': len(blocks), 'o0': 0, 'o1': 12, 'kind': 'body'}]}


class HTTPRepair(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='yedu-server-tests-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.books = self.root / 'books'
        self.web = self.root / 'web'
        self.books.mkdir(); self.web.mkdir()
        (self.web / 'index.html').write_text('fixture')
        values = {'DATA': self.root, 'BOOKS': self.books, 'WEB': self.web, 'PASSCODE': '',
                  'SECRET_FILE': self.root / '.cookie-secret', 'COOKIE_SECURE': True,
                  '_cache': storage.JsonCache(), '_pos_cache': app.OrderedDict(),
                  '_login_attempts': app.OrderedDict()}
        for name, value in values.items():
            p = patch.object(app, name, value); p.start(); self.addCleanup(p.stop)
        worker = jobs.Worker(self.books, app.APP, app.cached_json, app.wjson, enabled=False)
        p = patch.object(app, 'WORKER', worker); p.start(); self.addCleanup(p.stop)
        # Fail the suite if any unmocked external judge or generation path is accidentally used.
        for name in ['pipeline.llm._opener', 'pipeline.kind.jev']:
            p = patch(name, side_effect=AssertionError('network/model use forbidden'))
            p.start(); self.addCleanup(p.stop)
        self.server = app.BoundedHTTPServer(('127.0.0.1', 0), app.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        headers = dict(headers or {})
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode(); headers['Content-Type'] = 'application/json'
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        result = (response.status, dict(response.getheaders()), raw)
        conn.close()
        return result

    def make_book(self, name='fixture', image=False, state='done'):
        root = self.books / name; root.mkdir()
        app.wjson(root / 'book.json', book_fixture(image))
        app.wjson(root / 'meta.json', {'auto': False})
        app.wjson(root / 'status.json', {'state': state, 'frontier': 12})
        app.wjson(root / 'kg.json', {'log': [{'t': 'person', 'p': 1, 'id': 'p1', 'name': 'Alice'}]})
        app.wjson(root / 'mentions' / '0000.json', [[0, 5, 'p1']])
        if image:
            (root / 'img').mkdir(); (root / 'img' / 'cover.png').write_bytes(b'fixture-image')
        return root

    def test_old_epub_without_language_gets_english_shelf_estimate(self):
        root = self.make_book()
        book = book_fixture()
        book.pop('lang')
        book['blocks'][0]['t'] = 'Alice met Bob at the old house. ' * 20
        app.wjson(root / 'book.json', book)
        app.wjson(root / 'shelf.json', {'source': list(storage.signature(root / 'book.json')),
                                        'book': {'title': book['title'], 'len': book['len'], 'lang': None}})
        row = storage.shelf_metadata(root, app._cache)
        self.assertEqual(row['lang'], 'en')
        status, _, raw = self.request('GET', '/api/books')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)[0]['lang'], 'en')

    def test_upload_never_calls_judge_and_concurrent_same_upload_is_idempotent(self):
        barrier = threading.Barrier(2)
        real_parse = app.parse_file
        def parsing(*args):
            barrier.wait(timeout=3)
            return real_parse(*args)
        with patch.object(app, 'parse_file', side_effect=parsing):
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                futures = [pool.submit(self.request, 'POST', '/api/books', b'Alice came.\nBob left.',
                                       {'X-Filename': 'fixture.txt'}) for _ in range(2)]
                results = [f.result() for f in futures]
        self.assertEqual([x[0] for x in results], [200, 200])
        data = [json.loads(x[2]) for x in results]
        self.assertEqual(data[0]['id'], data[1]['id'])
        root = self.books / data[0]['id']
        self.assertTrue(json.loads((root / 'book.json').read_text())['genre_provisional'])
        self.assertFalse(data[0]['auto'])
        self.assertEqual(list(self.books.glob('.*.tmp')), [])

    def test_export_import_preserves_images_graph_progress_and_snapshot_state(self):
        self.make_book(image=True, state='running')
        app.wjson(self.root / 'progress.json', {'fixture': {'pos': 7, 'cutoff': 12, 't': 1}})
        status, _, raw = self.request('GET', '/api/books/fixture/export')
        self.assertEqual(status, 200)
        exported = json.loads(raw)
        self.assertEqual(exported['format'], 'yedu-book/2')
        status, _, raw = self.request('POST', '/api/books/import', exported)
        self.assertEqual(status, 200, raw)
        restored = json.loads(raw)
        self.assertEqual(restored['status']['state'], 'paused')
        self.assertEqual(restored['progress']['pos'], 7)
        self.assertEqual(restored['progress']['cutoff'], 12)
        self.assertEqual(restored['progress']['pct'], 100)
        status, _, raw = self.request('GET', f'/api/books/{restored["id"]}/img/cover.png')
        self.assertEqual((status, raw), (200, b'fixture-image'))
        self.assertEqual(json.loads((self.books / restored['id'] / 'mentions/0000.json').read_text()), [[0, 5, 'p1']])

    def test_import_rejects_bad_hash_and_unsorted_graph_without_publication(self):
        self.make_book(image=True)
        exported = json.loads(self.request('GET', '/api/books/fixture/export')[2])
        original = copy.deepcopy(exported)
        exported['assets']['cover.png']['sha256'] = '0' * 64
        self.assertEqual(self.request('POST', '/api/books/import', exported)[0], 400)
        original['kg']['log'] += [{'t': 'person', 'p': 0, 'id': 'p2', 'name': 'Bob'}]
        self.assertEqual(self.request('POST', '/api/books/import', original)[0], 400)
        self.assertEqual([p.name for p in self.books.iterdir()], ['fixture'])

    def test_legacy_text_export_import_works_but_missing_images_are_explicit(self):
        self.make_book()
        exported = json.loads(self.request('GET', '/api/books/fixture/export')[2])
        exported['format'] = 'yedu-book/1'; exported.pop('assets')
        self.assertEqual(self.request('POST', '/api/books/import', exported)[0], 200)
        exported['book'] = book_fixture(True)
        self.assertEqual(self.request('POST', '/api/books/import', exported)[0], 400)

    def test_conflicting_snapshot_is_not_silently_reused_or_overwritten(self):
        self.make_book()
        exported = json.loads(self.request('GET', '/api/books/fixture/export')[2])
        first = json.loads(self.request('POST', '/api/books/import', exported)[2])
        existing = self.books / first['id'] / 'kg.json'
        original = existing.read_bytes()
        exported['kg']['log'].append({'t': 'person', 'p': 2, 'id': 'p2', 'name': 'Bob'})
        self.assertEqual(self.request('POST', '/api/books/import', exported)[0], 409)
        self.assertEqual(existing.read_bytes(), original)

    def test_negative_length_and_transfer_encoding_rejected(self):
        self.assertEqual(self.request('POST', '/api/login', b'', {'Content-Length': '-1'})[0], 400)
        self.assertEqual(self.request('POST', '/api/login', b'', {'Transfer-Encoding': 'chunked'})[0], 400)

    def test_malformed_json_shape_and_expensive_request_admission(self):
        self.make_book()
        self.assertEqual(self.request('POST', '/api/login', [1, 2])[0], 400)
        self.assertEqual(self.request('POST', '/api/books/fixture/ask', {'q': [], 'pos': 2})[0], 400)
        with patch.object(app, '_ask_gate', threading.BoundedSemaphore(0)):
            self.assertEqual(self.request('POST', '/api/books/fixture/ask', {'q': 'Who?', 'pos': 2})[0], 429)

    def test_slow_incomplete_body_has_deadline(self):
        with patch.object(app, 'READ_TIMEOUT', .1):
            conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
            conn.request('POST', '/api/login', body=b'{}', headers={'Content-Length': '20'})
            response = conn.getresponse()
            self.assertEqual(response.status, 408)
            response.read(); conn.close()

    def test_static_sibling_cannot_escape_root(self):
        sibling = self.root / 'web-private'; sibling.mkdir()
        (sibling / 'secret.txt').write_text('fixture-only')
        for path in ['/../web-private/secret.txt', '/%2e%2e/web-private/secret.txt']:
            self.assertEqual(self.request('GET', path)[0], 404)

    def test_static_revalidation_and_compression(self):
        source = 'export const x = 1;\n' * 400
        (self.web / 'a.js').write_text(source)
        status, headers, raw = self.request('GET', '/a.js', headers={'Accept-Encoding': 'gzip'})
        self.assertEqual((status, headers['Content-Encoding']), (200, 'gzip'))
        self.assertEqual(gzip.decompress(raw).decode(), source)
        etag = headers['ETag']
        status, headers, raw = self.request('GET', '/a.js', headers={'If-None-Match': etag})
        self.assertEqual((status, raw, headers['ETag']), (304, b'', etag))
        self.assertEqual(self.request('GET', '/a.js')[2].decode(), source)
        (self.web / 'a.js').write_text(source + '// changed\n')
        status, headers, raw = self.request('GET', '/a.js', headers={'If-None-Match': etag})
        self.assertEqual(status, 200)
        self.assertNotEqual(headers['ETag'], etag)
        self.assertTrue(raw.decode().endswith('// changed\n'))

    def test_byline_in_file_name_is_shown_as_title_and_author(self):
        self.assertEqual(storage.display_title('术师手册 作者：听日', ''), ('术师手册', '听日'))
        self.assertEqual(storage.display_title('瑜伽师地论 作者：', ''), ('瑜伽师地论', ''))
        self.assertEqual(storage.display_title('哈佛幸福课 作者：ePUBw.COM', ''), ('哈佛幸福课', ''))
        self.assertEqual(storage.display_title('老千 作者：马小虎', '别人'), ('老千', '别人'))
        self.assertEqual(storage.display_title('红楼梦', '曹雪芹'), ('红楼梦', '曹雪芹'))
        root = self.make_book()
        book = json.loads((root / 'book.json').read_text())
        book.update(title='术师手册 作者：听日', author='')
        app.wjson(root / 'book.json', book)
        shelf = json.loads(self.request('GET', '/api/books')[2])
        self.assertEqual((shelf[0]['title'], shelf[0]['author']), ('术师手册', '听日'))
        detail = json.loads(self.request('GET', '/api/books/fixture')[2])
        self.assertEqual((detail['title'], detail['author']), ('术师手册', '听日'))

    def test_optimistic_progress_does_not_overwrite_other_device(self):
        self.make_book()
        first = self.request('PUT', '/api/books/fixture/progress', {'pos': 3, 'expected_t': None})
        self.assertEqual(first[0], 200)
        progress = json.loads(first[2])['progress']
        conflict = self.request('PUT', '/api/books/fixture/progress', {'pos': 6, 'expected_t': None})
        self.assertEqual(conflict[0], 409)
        self.assertEqual(json.loads(conflict[2])['progress'], progress)
        self.assertEqual(self.request('PUT', '/api/books/fixture/progress', {'pos': 13})[0], 400)

    def test_explicit_process_queues_completed_pending_quality(self):
        root = self.make_book()
        quality = {'state': 'pending', 'pending': ['quarantined-derived-cache']}
        app.wjson(root / 'status.json', {'state': 'done', 'frontier': 12, 'quality': quality})
        status, _, raw = self.request('POST', '/api/books/fixture/process')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(raw)['status']['state'], 'queued')
        self.assertEqual(json.loads(raw)['status']['quality'], quality)
        self.assertTrue(app.cached_json(root / 'meta.json')['retry_quality'])
        self.assertEqual(self.request('DELETE', '/api/books/fixture/process')[0], 200)
        self.assertNotIn('retry_quality', app.cached_json(root / 'meta.json'))

    def test_progress_end_cutoff_reaches_100_without_losing_resume_anchor(self):
        self.make_book()
        status, _, raw = self.request('PUT', '/api/books/fixture/progress', {'pos': 7, 'cutoff': 12})
        self.assertEqual(status, 200)
        progress = json.loads(raw)['progress']
        self.assertEqual((progress['pos'], progress['cutoff'], progress['pct']), (7, 12, 100))
        for cutoff in [6, 13, -1, 9.5, True, '12']:
            self.assertEqual(self.request('PUT', '/api/books/fixture/progress', {'pos': 7, 'cutoff': cutoff})[0], 400)
        legacy = json.loads(self.request('PUT', '/api/books/fixture/progress', {'pos': 6})[2])['progress']
        self.assertEqual((legacy['pos'], legacy['cutoff'], legacy['pct']), (6, 6, 50))

    def test_cookie_is_secure_expiring_and_authentication_required(self):
        with patch.object(app, 'PASSCODE', 'fixture-pass'):
            self.assertEqual(self.request('GET', '/api/books')[0], 401)
            status, headers, _ = self.request('POST', '/api/login', {'code': 'fixture-pass'})
            self.assertEqual(status, 200)
            cookie = headers['Set-Cookie']
            self.assertIn('Secure', cookie); self.assertIn('HttpOnly', cookie)
            self.assertEqual(self.request('GET', '/api/books', headers={'Cookie': cookie.split(';')[0]})[0], 200)
            with patch.object(app.time, 'time', return_value=time.time() + 8 * 86400):
                self.assertEqual(self.request('GET', '/api/books', headers={'Cookie': cookie.split(';')[0]})[0], 401)

    def test_health_disabled_worker_and_manifest_revision(self):
        status, headers, raw = self.request('GET', '/healthz')
        self.assertEqual(status, 200); self.assertTrue(json.loads(raw)['ok'])
        self.assertIn('X-Yedu-Release', headers)
        root = self.make_book(image=True)
        manifest = json.loads(self.request('GET', '/api/books/fixture/offline-manifest')[2])
        self.assertEqual(manifest['book']['id'], 'fixture')
        self.assertEqual(manifest['book']['version'], json.loads(self.request('GET', '/api/books/fixture')[2])['version'])
        self.assertEqual(manifest['graph']['to'], 12)
        self.assertIn('/api/books/fixture/img/cover.png', manifest['assets'])
        app.wjson(root / 'status.json', {'state': 'done', 'frontier': 11})
        changed = json.loads(self.request('GET', '/api/books/fixture/offline-manifest')[2])
        self.assertNotEqual(changed['version'], manifest['version'])
        app.WORKER.enabled = True
        self.assertEqual(self.request('GET', '/healthz')[0], 503)

    def test_delete_busy_external_book_refuses_and_keeps_content(self):
        root = self.make_book(state='running')
        with jobs.book_lease(root):
            status, _, _ = self.request('DELETE', '/api/books/fixture')
        self.assertEqual(status, 409)
        self.assertTrue((root / 'book.json').exists())

    def test_delete_archives_data_and_clears_progress(self):
        root = self.make_book()
        app.wjson(self.root / 'progress.json', {'fixture': {'pos': 2}})
        self.assertEqual(self.request('DELETE', '/api/books/fixture')[0], 200)
        self.assertFalse(root.exists())
        self.assertTrue(next((self.root / 'trash').glob('fixture-*')).joinpath('book.json').exists())
        self.assertEqual(app.progress_all(), {})

    def test_shelf_uses_small_metadata_and_reflects_book_updates(self):
        root = self.make_book()
        self.request('GET', '/api/books')
        self.assertTrue((root / 'shelf.json').exists())
        real_read = Path.read_text
        def read(path, *args, **kwargs):
            if path == root / 'book.json':
                raise AssertionError('shelf reloaded body')
            return real_read(path, *args, **kwargs)
        with patch.object(Path, 'read_text', read):
            self.assertEqual(self.request('GET', '/api/books')[0], 200)
        book = book_fixture(); book['title'] = 'Updated'
        app.wjson(root / 'book.json', book)
        self.assertEqual(json.loads(self.request('GET', '/api/books')[2])[0]['title'], 'Updated')


class QualityRepair(unittest.TestCase):
    def test_shared_temporal_contract(self):
        cases = json.loads((Path(__file__).parent / 'temporal-fixtures.json').read_text())['cases']
        for case in cases:
            with self.subTest(case=case['name']):
                rels = list(fold(case['records'], case['cutoff'])['rels'].values())
                self.assertEqual(len(rels), len(case['expected_rels']))
                for got, expected in zip(rels, case['expected_rels']):
                    self.assertEqual({k: got.get(k) for k in expected}, expected)

    def test_early_and_merged_latest_attributes_preserved(self):
        log = [{'t': 'attr', 'p': 1, 'id': 'a', 'key': 'job', 'value': 'teacher'},
               {'t': 'person', 'p': 2, 'id': 'a', 'name': 'Alice'},
               {'t': 'person', 'p': 3, 'id': 'b', 'name': 'Alias'},
               {'t': 'attr', 'p': 4, 'id': 'b', 'key': 'job', 'value': 'writer'},
               {'t': 'merge', 'p': 5, 'from': 'b', 'into': 'a'}]
        self.assertEqual(fold(log, 2)['people']['a']['attrs']['job'], 'teacher')
        self.assertEqual(fold(log, 5)['people']['a']['attrs']['job'], 'writer')

    def test_failed_guard_never_publishes_rejected_prose(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'books' / 'fixture'; root.mkdir(parents=True)
            book = book_fixture(); book['lang'] = 'zh'
            payload = {'book.json': book, 'kg.json': {'log': []}, 'status.json': {}}
            for guard in [[{'a': {'verdict': 'flag', 'p': .01}}] * 2, RuntimeError('fixture outage')]:
                events = []
                with patch.object(ask, 'route_question', return_value=('other', {})), \
                     patch.object(ask, 'retrieve', return_value=[]), \
                     patch.object(ask, 'chat', side_effect=[('REJECTED FIRST', {}), ('REJECTED SECOND', {})]), \
                     patch.object(ask, 'guard_texts', side_effect=guard):
                    ask.answer(root, '发生了什么？', 12, lambda k, v: events.append((k, v)), lambda p: payload[p.name])
                answer = next(v for k, v in events if k == 'answer')
                self.assertNotIn('REJECTED', json.dumps(answer))
                self.assertEqual(answer['guard']['verdict'], 'withheld')
                self.assertEqual(answer['cites'], [])

    def test_ended_relationship_is_explicitly_historical_in_answer_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'books' / 'fixture'; root.mkdir(parents=True)
            log = [{'t': 'person', 'p': 0, 'id': 'a', 'name': 'Alice'},
                   {'t': 'person', 'p': 0, 'id': 'b', 'name': 'Bob'},
                   {'t': 'rel', 'p': 3, 'a': 'a', 'b': 'b', 'a_is': 'wife', 'b_is': 'husband', 'status': 'ended'}]
            payload = {'book.json': book_fixture(), 'kg.json': {'log': log}, 'status.json': {}}
            with patch.object(ask, 'route_question', return_value=('relation', {})), \
                 patch.object(ask, 'retrieve', return_value=[]), \
                 patch.object(ask, 'chat', return_value=('They were married.', {})) as chat, \
                 patch.object(ask, 'guard_texts', return_value={'a': {'verdict': 'ok', 'p': .95}}):
                ask.answer(root, 'How are Alice and Bob related?', 12, lambda *_: None, lambda p: payload[p.name])
            self.assertIn('过去的关系，已结束', chat.call_args.args[1][1]['content'])

    def test_multilingual_fallback_and_query_translation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); book = book_fixture()
            (root / 'book.json').write_text(json.dumps(book))
            self.assertTrue(ask.retrieve(root, book, '她为什么来了？', [], 12))
            with patch.object(ask, 'chat', return_value=('Why did she come?', {})) as chat:
                self.assertIn('Why did she come?', ask.retrieval_query('她为什么来了？', book))
                chat.assert_called_once()
            self.assertTrue(all(p['o'] + len(p['t'].encode('utf-16-le')) // 2 <= 5
                                for p in ask.retrieve(root, book, 'Alice', [], 5)))

    def test_pronoun_exact_span_and_local_candidate(self):
        log = [{'t': 'person', 'p': 0, 'id': f'p{i}', 'name': f'Person{i}'} for i in range(20)]
        log.append({'t': 'cnt', 'p': 0, 'c': {f'p{i}': 100 if i < 19 else 1 for i in range(20)}})
        book = {'blocks': [{'o': 0, 't': 'Person19 arrived. He sat down.'}]}
        with patch.object(ask, 'jev', return_value={'w': {'choice': 'p19', 'probabilities': {'p19': .9}}}) as judge:
            result = ask.who_is(book, log, 29, 18, 20)
        self.assertTrue(result['ok'])
        self.assertIn('p19', judge.call_args.args[1]['w']['criteria'])
        self.assertIn('<selected>He</selected>', judge.call_args.args[0]['this_passage'])

    def test_cache_budget_and_corruption_visibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = storage.JsonCache(count=2, budget=1000, item_limit=1000)
            paths = [Path(tmp) / f'{i}.json' for i in range(3)]
            for i, path in enumerate(paths):
                storage.write_json(path, {'n': i}); cache.get(path)
            self.assertEqual(len(cache.entries), 2)
            paths[-1].write_text('not json')
            with self.assertRaises(json.JSONDecodeError): cache.get(paths[-1])

    def test_concurrent_cache_read_parses_one_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'book.json'; storage.write_json(path, book_fixture())
            cache = storage.JsonCache(); calls = []
            real_read = Path.read_text
            def slow_read(p, *args, **kwargs):
                calls.append(p); time.sleep(.05)
                return real_read(p, *args, **kwargs)
            with patch.object(Path, 'read_text', slow_read), concurrent.futures.ThreadPoolExecutor(2) as pool:
                result = list(pool.map(cache.get, [path, path]))
            self.assertIs(result[0], result[1]); self.assertEqual(len(calls), 1)

    def test_worker_cancel_owned_process_and_spawn_error_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            books = Path(tmp); root = books / 'fixture'; root.mkdir()
            cache = storage.JsonCache()
            storage.write_json(root / 'book.json', book_fixture())
            storage.write_json(root / 'meta.json', {'auto': True})
            storage.write_json(root / 'status.json', {'state': 'queued'})
            worker = jobs.Worker(books, books, cache.get, storage.write_json)
            with patch.object(jobs.subprocess, 'Popen', side_effect=OSError('fixture spawn failure')):
                with self.assertRaises(OSError): worker._one(root)
            self.assertIsNone(worker.current); self.assertIsNone(worker.process)
            real_popen = subprocess.Popen
            def fixture_process(*args, **kwargs):
                return real_popen([os.sys.executable, '-c', 'import time; time.sleep(30)'], **kwargs)
            with patch.object(jobs.subprocess, 'Popen', side_effect=fixture_process):
                thread = threading.Thread(target=worker._one, args=(root,)); thread.start()
                deadline = time.monotonic() + 3
                while worker.process is None and time.monotonic() < deadline: time.sleep(.01)
                process = worker.process; self.assertIsNotNone(process)
                worker.cancel(root, timeout=2)
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive()); self.assertIsNotNone(process.poll())
            self.assertEqual(cache.get(root / 'status.json')['state'], 'paused')
            self.assertTrue((root / 'book.json').exists())
            # A service restart should preserve automatic resumption instead of user-pausing it.
            worker.set_auto(root, True)
            with patch.object(jobs.subprocess, 'Popen', side_effect=fixture_process):
                thread = threading.Thread(target=worker._one, args=(root,)); thread.start()
                deadline = time.monotonic() + 3
                while worker.process is None and time.monotonic() < deadline: time.sleep(.01)
                self.assertIsNotNone(worker.process)
                worker.stop(); worker.cancel(root, timeout=2, preserve_auto=True)
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
            self.assertTrue(cache.get(root / 'meta.json')['auto'])
            self.assertEqual(cache.get(root / 'status.json')['state'], 'queued')

    def test_worker_loop_survives_spawn_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            books = Path(tmp); root = books / 'fixture'; root.mkdir()
            cache = storage.JsonCache()
            storage.write_json(root / 'book.json', book_fixture())
            storage.write_json(root / 'meta.json', {'auto': True})
            worker = jobs.Worker(books, books, cache.get, storage.write_json)
            with patch.object(jobs.subprocess, 'Popen', side_effect=OSError('fixture spawn failure')):
                worker.wake.set(); worker.start()
                try:
                    deadline = time.monotonic() + 3
                    while worker.last_error is None and time.monotonic() < deadline: time.sleep(.01)
                    self.assertIsNotNone(worker.last_error)
                    self.assertTrue(worker.is_alive())
                    self.assertIsNone(worker.current)
                finally:
                    worker.stop(); worker.join(timeout=3)

    def test_quality_retry_requires_explicit_request_and_survives_launch_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            books = Path(tmp); root = books / 'fixture'; root.mkdir()
            cache = storage.JsonCache()
            storage.write_json(root / 'book.json', book_fixture())
            storage.write_json(root / 'meta.json', {'auto': True})
            storage.write_json(root / 'status.json', {
                'state': 'done', 'quality': {'state': 'pending', 'pending': ['unsafe-summary']}})
            worker = jobs.Worker(books, books, cache.get, storage.write_json)
            with patch.object(jobs.subprocess, 'Popen') as launch:
                worker._one(root)
                launch.assert_not_called()
            worker.set_auto(root, True)
            with patch.object(jobs.subprocess, 'Popen', side_effect=OSError('fixture spawn failure')):
                with self.assertRaises(OSError): worker._one(root)
            self.assertTrue(cache.get(root / 'meta.json')['retry_quality'])
            # The lock can be taken between the parent's probe and the child launch.
            with patch.object(jobs.subprocess, 'Popen', return_value=Mock(wait=Mock(return_value=75))):
                worker._one(root)
            self.assertTrue(cache.get(root / 'meta.json')['retry_quality'])
            with patch.object(jobs.subprocess, 'Popen', return_value=Mock(wait=Mock(return_value=1))):
                worker._one(root)
            self.assertTrue(cache.get(root / 'meta.json')['retry_quality'])
            worker.set_auto(root, True)
            def finish():
                storage.write_json(root / 'work' / 'quality-retry.json', {
                    'state': 'complete', 'archive': 'work/retry-archive/fixture'})
                storage.write_json(root / 'status.json', {
                    'state': 'done', 'quality': {'state': 'verified', 'pending': []}})
                return 0
            with patch.object(jobs.subprocess, 'Popen', return_value=Mock(wait=Mock(side_effect=finish))) as launch:
                worker._one(root)
                self.assertIn('--retry-quality', launch.call_args.args[0])
            self.assertNotIn('retry_quality', cache.get(root / 'meta.json'))
            self.assertEqual(cache.get(root / 'status.json')['quality']['state'], 'verified')


if __name__ == '__main__':
    unittest.main()
