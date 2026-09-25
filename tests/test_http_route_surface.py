"""Keep the committed HTTP oracle closed over Handler.route's declared surface."""
from __future__ import annotations

import ast
import json
import unittest
from pathlib import Path

from oracle.record.http_routes import coverage_report, route_family


ROOT = Path(__file__).resolve().parents[1]
GOLDENS = ROOT / 'oracle/goldens/http'
BOOK_RESOURCE_PATTERNS = {
    'm': ('/api/books/([A-Za-z0-9_-]+)(/.*)?', 'path'),
    'm2': (r'/chapters/(\d+)', 'rest'),
    'm3': ('/img/([A-Za-z0-9_.-]+)', 'rest'),
}
REGEX_FAMILIES = {
    'm2': '/api/books/{book}/chapters/{chapter}',
    'm3': '/api/books/{book}/img/{image}',
}
# These two routes deliberately have no method guard. GET is their reviewed
# representative; HEAD and other generic method behavior is a separate concern.
METHOD_NEUTRAL_FAMILIES = {'static', '/api/me'}
EXTRA_RECORDED_PAIRS = {
    ('/api/does-not-exist', 'GET'),  # reviewed unknown-API response
    ('/healthz', 'HEAD'),           # do_HEAD delegates to do_GET
    ('/api/books/{book}', 'HEAD'),
}


def _route_surface() -> tuple[set[tuple[str, str]], set[str], int]:
    tree = ast.parse((ROOT / 'server/app.py').read_text(encoding='utf-8'))
    handler = next(node for node in tree.body
                   if isinstance(node, ast.ClassDef) and node.name == 'Handler')
    route = next(node for node in handler.body
                 if isinstance(node, ast.FunctionDef) and node.name == 'route')
    regexes = {}
    for node in ast.walk(route):
        if not isinstance(node, ast.Assign) or len(node.targets) != 1 \
                or not isinstance(node.targets[0], ast.Name):
            continue
        call = node.value
        if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Attribute) \
                or not isinstance(call.func.value, ast.Name) \
                or (call.func.value.id, call.func.attr) != ('re', 'fullmatch'):
            continue
        if len(call.args) != 2 or not isinstance(call.args[0], ast.Constant) \
                or not isinstance(call.args[1], ast.Name):
            raise AssertionError(f'unreviewed route regex at server/app.py:{node.lineno}')
        regexes[node.targets[0].id] = (call.args[0].value, call.args[1].id)
    if regexes != BOOK_RESOURCE_PATTERNS:
        raise AssertionError(f'Handler.route resource patterns changed: {regexes}')

    explicit: set[tuple[str, str]] = set()
    neutral: set[str] = set()
    gate_count = 0
    for node in ast.walk(route):
        if not isinstance(node, ast.If):
            continue
        names = {part.id for part in ast.walk(node.test) if isinstance(part, ast.Name)}
        if not ({'path', 'rest'} | (regexes.keys() - {'m'})) & names:
            continue
        gate_count += 1
        comparisons = [part for part in ast.walk(node.test)
                       if isinstance(part, ast.Compare)]
        endpoint = [part for part in comparisons
                    if isinstance(part.left, ast.Name)
                    and part.left.id in ('path', 'rest')]
        if endpoint:
            if len(endpoint) != 1 or len(endpoint[0].ops) != 1 \
                    or not isinstance(endpoint[0].ops[0], ast.Eq) \
                    or not isinstance(endpoint[0].comparators[0], ast.Constant) \
                    or not isinstance(endpoint[0].comparators[0].value, str):
                raise AssertionError(f'unreviewed route gate at server/app.py:{node.lineno}')
            field = endpoint[0].left.id
            value = endpoint[0].comparators[0].value
            family = value if field == 'path' else '/api/books/{book}' + value
        elif 'm2' in names or 'm3' in names:
            aliases = ({'m2', 'm3'} & names)
            if len(aliases) != 1:
                raise AssertionError(f'unreviewed regex gate at server/app.py:{node.lineno}')
            family = REGEX_FAMILIES[aliases.pop()]
        elif ast.unparse(node.test) == "not path.startswith('/api/')":
            family = 'static'
        else:
            raise AssertionError(f'unreviewed route gate at server/app.py:{node.lineno}')

        methods: set[str] = set()
        for part in comparisons:
            if not isinstance(part.left, ast.Name) or part.left.id != 'method':
                continue
            if len(part.ops) != 1:
                raise AssertionError(f'unreviewed method gate at server/app.py:{node.lineno}')
            if isinstance(part.ops[0], ast.Eq) and isinstance(part.comparators[0], ast.Constant):
                methods.add(part.comparators[0].value)
            elif isinstance(part.ops[0], ast.In) and isinstance(part.comparators[0], ast.Tuple) \
                    and all(isinstance(item, ast.Constant) for item in part.comparators[0].elts):
                methods.update(item.value for item in part.comparators[0].elts)
            else:
                raise AssertionError(f'unreviewed method gate at server/app.py:{node.lineno}')
        if methods:
            explicit.update((family, method) for method in methods)
        else:
            neutral.add(family)
    return explicit, neutral, gate_count


class HTTPRouteSurfaceTests(unittest.TestCase):
    def test_every_declared_route_method_has_a_committed_success_response(self):
        explicit, neutral, gates = _route_surface()
        self.assertEqual(gates, 28)
        self.assertEqual(len(explicit), 32)
        self.assertEqual(neutral, METHOD_NEUTRAL_FAMILIES)

        observed: set[tuple[str, str]] = set()
        successful: set[tuple[str, str]] = set()
        for name, count in (('aq_complete', 60), ('aq_model_synthetic', 4),
                            ('aq_edges_synthetic', 18)):
            rows = [json.loads(line) for line in
                    (GOLDENS / f'{name}.jsonl').read_text(encoding='utf-8').splitlines()]
            report = json.loads((GOLDENS / f'{name}-report.json').read_text(encoding='utf-8'))
            self.assertEqual(len(rows), count, name)
            self.assertEqual(report['routes'], count, name)
            self.assertEqual(report['families'], coverage_report(rows), name)
            for row in rows:
                pair = (route_family(row['request']['path']), row['request']['method'])
                observed.add(pair)
                body = row['response'].get('body_json')
                if row['response']['status'] < 400 and not (
                        isinstance(body, dict) and body.get('ok') is False):
                    successful.add(pair)

        representative = {(family, 'GET') for family in neutral}
        self.assertEqual(observed, explicit | representative | EXTRA_RECORDED_PAIRS)
        self.assertFalse((explicit | representative) - successful)


if __name__ == '__main__':
    unittest.main()
