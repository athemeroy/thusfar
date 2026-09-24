"""Check bundled UI catalogs and Android native strings without external packages."""
from __future__ import annotations

import ast
import json
import re
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ('en', 'es', 'fr', 'de', 'pt-BR', 'ja', 'ko')
QUALIFIERS = {'en': 'values', 'es': 'values-es', 'fr': 'values-fr', 'de': 'values-de',
              'pt-BR': 'values-pt-rBR', 'ja': 'values-ja', 'ko': 'values-ko', 'zh-CN': 'values-zh'}
LITERAL = re.compile(r'''\b(?:tr|t)\s*\(\s*(?P<literal>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')''')
PLACEHOLDER = re.compile(r'\{[A-Za-z0-9_]+\}')


def strings(path: Path) -> dict[str, str]:
    return {row.attrib['name']: row.text or '' for row in ElementTree.parse(path).getroot()}


def server_errors() -> set[str]:
    keys = set()
    for path in (ROOT / 'server').glob('*.py'):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call) and isinstance(node.exc.func, ast.Name) \
                    and node.exc.func.id in {'ValueError', 'BusyBook', 'RuntimeError', 'PermissionError', 'FileNotFoundError'} \
                    and node.exc.args and isinstance(node.exc.args[0], ast.Constant) and isinstance(node.exc.args[0].value, str):
                keys.add(node.exc.args[0].value)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'err' \
                    and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str):
                keys.add(node.args[1].value)
            if isinstance(node, ast.Dict):
                for name, value in zip(node.keys, node.values):
                    if isinstance(name, ast.Constant) and name.value == 'error' and isinstance(value, ast.Constant) and isinstance(value.value, str):
                        keys.add(value.value)
            if isinstance(node, ast.keyword) and node.arg == 'error' and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                keys.add(node.value.value)
    return {value for value in keys if re.search(r'[\u3400-\u9fff]', value)}


def main() -> None:
    web_keys = set()
    for path in (ROOT / 'web/js').glob('*.js'):
        if path.name == 'i18n-catalogs.js':
            continue
        web_keys.update(ast.literal_eval(match['literal']) for match in LITERAL.finditer(path.read_text()))
    chinese = strings(ROOT / 'android/app/src/main/res/values-zh/strings.xml')
    required = web_keys | set(chinese.values()) | server_errors()
    for locale in LOCALES:
        source = (ROOT / 'web/js/locales' / f'{locale}.js').read_text()
        assert source.startswith('export default {') and source.rstrip().endswith('};'), locale
        catalog = json.loads(source.removeprefix('export default ').removesuffix(';\n').rstrip(' \n;'))
        assert set(catalog) == required, (locale, 'missing', sorted(required - set(catalog))[:5], 'extra', sorted(set(catalog) - required)[:5])
        for key, value in catalog.items():
            assert isinstance(value, str) and value.strip(), (locale, key)
            assert sorted(PLACEHOLDER.findall(key)) == sorted(PLACEHOLDER.findall(value)), (locale, key, value)
            assert 'ZXQPH' not in value, (locale, key, value)
        native = strings(ROOT / 'android/app/src/main/res' / QUALIFIERS[locale] / 'strings.xml')
        assert set(native) == set(chinese), (locale, 'native resource keys')
    print(f'{len(web_keys)} web keys; {len(chinese)} native strings; {len(server_errors())} server errors; seven complete offline catalogs')


if __name__ == '__main__':
    main()
