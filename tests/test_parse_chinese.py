"""中文回目与正文回指的边界回归。"""
import tempfile
import unittest
from pathlib import Path

from pipeline.parse import parse_txt, _html_book, u16


class ChineseChapterBoundary(unittest.TestCase):
    def test_reference_stays_in_fifth_chapter(self):
        reference = '第四回中既将薛家母子在荣府内寄居等事略已表明，此回则暂不能写矣。'
        titles = ['第四回 葫芦僧乱判葫芦案', '第五回游幻境指迷十二钗']
        lines = [titles[0], '正文。' * 100, titles[1], reference, '后文。' * 100]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '书.txt'
            path.write_text('\n'.join(lines))
            books = [parse_txt(path, Path(directory)),
                     _html_book(''.join(f'<p>{line}</p>' for line in lines), '书')]
        for book in books:
            with self.subTest(format=book.get('lang', 'html')):
                self.assertEqual([c['title'] for c in book['chapters']], titles)
                fifth = book['chapters'][1]
                self.assertIn(reference, [b['t'] for b in book['blocks'][fifth['b0']:fifth['b1']]])
                self.assertEqual(book['len'], sum(u16(b['t']) + 1 for b in book['blocks']))


if __name__ == '__main__':
    unittest.main()
