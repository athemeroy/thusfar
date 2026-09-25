"""Estimate the five A0 books using the parser, segmenter and configured gateway rates.

This is a planning bound, not a receipt: JEV may reclassify chapters and later model stages,
retries, and repairs depend on actual answers. It never invokes a model or the network.
"""
from __future__ import annotations

import argparse
import hashlib
import tempfile
from pathlib import Path

from pipeline.extract import segments
from pipeline.lang import book_lang
from pipeline.models import LATIN_FACTOR, PRICES, RATES
from pipeline.parse import parse_file

from .common import write_json

ROOT = Path(__file__).resolve().parents[2]
MODEL = 'deepseek-flash'


def estimate(source_dir: Path) -> dict:
    price = PRICES[MODEL]['price']
    rate = RATES[MODEL]['tokens']
    rows = []
    with tempfile.TemporaryDirectory(prefix='thusfar-cost-estimate-') as temp:
        for source in sorted(source_dir.glob('*.txt')):
            book = parse_file(source, Path(temp) / source.stem)
            body = [i for i, chapter in enumerate(book['chapters'])
                    if chapter.get('kind') == 'body']
            segs = segments(book, body)
            lang = book_lang(book)
            units = book['len'] / 10_000 * (1 if lang in ('zh', 'ja', None, '') else LATIN_FACTOR)
            prompt = rate[0] * units
            completion = rate[1] * units
            cost = (prompt * price[0] + completion * price[1]) / 1_000_000
            rows.append({'file': source.name,
                         'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                         'language': lang,
                         'parsed_utf16_chars': book['len'],
                         'chapters': len(book['chapters']),
                         'parser_body_chapters': len(body),
                         'parser_body_segments': len(segs),
                         'estimated_prompt_tokens': round(prompt),
                         'estimated_completion_tokens': round(completion),
                         'estimated_cny': round(cost, 6)})
    return {'schema': 1,
            'model': MODEL + '+nothink',
            'gateway_price_cny_per_million_tokens': {'input': price[0], 'output': price[1]},
            'measured_tokens_per_10000_effective_chars': {'input': rate[0], 'output': rate[1]},
            'latin_character_factor': LATIN_FACTOR,
            'assumptions': [
                'The initial parser body chapter classification remains unchanged by JEV.',
                'One local extraction request is made for each parser body segment.',
                'Token counts use pipeline.models measured rates; no classification, biography, '
                'recap, relation wording, repair, or retry requests are included.',
                'Free JEV has zero fee; network requests and model responses were not made.'
            ],
            'books': rows,
            'total': {'parser_body_segments': sum(row['parser_body_segments'] for row in rows),
                      'estimated_cny': round(sum(row['estimated_cny'] for row in rows), 6)}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=ROOT / 'oracle/corpus/books')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = estimate(args.source_dir)
    write_json(args.out, report)
    total = report['total']
    print(f'estimated {total["parser_body_segments"]} first-pass model requests, '
          f'¥{total["estimated_cny"]:.3f} before answer-dependent stages')


if __name__ == '__main__':
    main()
