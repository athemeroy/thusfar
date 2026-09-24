"""Regression coverage for Japanese TXT books whose markup was removed before upload."""
import tempfile
import unittest
from pathlib import Path

from pipeline.parse import parse_txt, u16


class JapanesePlainText(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'book.txt'
            path.write_text(text, encoding='utf-8')
            return parse_txt(path, Path(directory))

    def test_preface_does_not_swallow_numbered_parts(self):
        preface = 'この本は雪の結晶について研究したものです。' * 30
        story = '雪がどのようにできるかを調べていました。' * 30
        book = self.parse('\n\n'.join([
            '雪', '第１図版', '序', preface, '第一　雪と人生', '一', story,
            '二', story, '第二　「雪の結晶」雑話', '一', story,
        ]))
        self.assertEqual(book['lang'], 'ja')
        chapters = book['chapters']
        self.assertEqual(next(c for c in chapters if c['title'] == '序')['kind'], 'front')
        body = [c for c in chapters if c['kind'] == 'body']
        self.assertTrue(body)
        self.assertTrue(any('第一　雪と人生' in c['title'] for c in chapters))
        self.assertTrue(any('第二　「雪の結晶」雑話' in c['title'] for c in chapters))
        self.assertFalse(any(c['title'] == '第１図版' for c in chapters))
        self.assertTrue(all(story in ''.join(b['t'] for b in book['blocks'][c['b0']:c['b1']])
                            for c in body if c['title'] in ('一', '二')))

    def test_notebooks_and_narrative_frames_are_chapters(self):
        paragraph = '私は、その人について何も知らなかったのです。' * 30
        titles = ['はしがき', '第一の手記', '第二の手記', '第三の手記', 'あとがき']
        book = self.parse('\n\n'.join(['人間失格'] + [x for t in titles for x in (t, paragraph)]))
        self.assertEqual([c['title'] for c in book['chapters']][1:], titles)
        self.assertTrue(all(c['kind'] == 'body' for c in book['chapters'][1:]))

    def test_named_upper_middle_lower_parts_preserve_offsets(self):
        paragraph = '私は先生と呼んでいた人のところへ行きました。😀' * 30
        book = self.parse('\n\n'.join([
            'こころ', '上　先生と私', '一', paragraph,
            '中　両親と私', '一', paragraph, '下　先生と遺書', '一', paragraph,
        ]))
        self.assertTrue(all(any(t in c['title'] for c in book['chapters'])
                            for t in ('上　先生と私', '中　両親と私', '下　先生と遺書')))
        offset = 0
        for block in book['blocks']:
            self.assertEqual(block['o'], offset)
            offset += u16(block['t']) + 1
        self.assertEqual(book['len'], offset)

    def test_chinese_headings_keep_their_existing_structure(self):
        paragraph = '一个人在屋外看着落下的雪，想起多年前的朋友。' * 30
        book = self.parse('\n\n'.join(['书名', '序', paragraph, '第一章 雪', paragraph, '第二章 人', paragraph]))
        self.assertEqual(book['lang'], 'zh')
        self.assertEqual([c['title'] for c in book['chapters']], ['开始', '序', '第一章 雪', '第二章 人'])


if __name__ == '__main__':
    unittest.main()
