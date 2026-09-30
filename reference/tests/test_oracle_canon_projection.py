"""The KG.canon trace records its semantic inputs, not unrelated KG changes."""

from __future__ import annotations

import sys
import unittest

from oracle.record.functions import Collector
from pipeline.kg import KG


class CanonProjectionTests(unittest.TestCase):
    def test_merge_chain_is_complete_and_unrelated_mentions_do_not_split_sample(self):
        function = 'pipeline.kg.KG.canon'
        locations = {('pipeline/kg.py', KG.canon.__code__.co_firstlineno): function}
        collector = Collector({function}, locations, (), 100)
        kg = KG({'lang': 'zh', 'blocks': []})
        kg.people = {
            'P1': {'name': '旧名', 'mentions': 5, 'merged_into': 'P2'},
            'P2': {'name': '中间名', 'mentions': 7, 'merged_into': 'P3'},
            'P3': {'name': '现名', 'mentions': 11},
            'P9': {'name': '无关者', 'mentions': 1},
        }
        previous = sys.gettrace()
        try:
            sys.settrace(collector.trace)
            self.assertEqual(kg.canon('P1'), 'P3')
            kg.people['P9']['mentions'] = 999
            kg.people['P1']['mentions'] = 12
            self.assertEqual(kg.canon('P1'), 'P3')
        finally:
            sys.settrace(previous)
        self.assertEqual(collector.calls[function], 2)
        self.assertEqual(len(collector.samples[function]), 1)
        sample = next(iter(collector.samples[function].values()))
        self.assertEqual(sample['input'], {
            'self': {'$object': 'pipeline.kg.KG', 'fields': {'people': {
                'P1': {'merged_into': 'P2'},
                'P2': {'merged_into': 'P3'},
                'P3': {},
            }}},
            'pid': 'P1',
        })
        self.assertEqual(sample['output'], 'P3')

    def test_cycle_keeps_closing_edge(self):
        function = 'pipeline.kg.KG.canon'
        locations = {('pipeline/kg.py', KG.canon.__code__.co_firstlineno): function}
        collector = Collector({function}, locations, (), 100)
        kg = KG({'lang': 'zh', 'blocks': []})
        kg.people = {'P1': {'merged_into': 'P2'}, 'P2': {'merged_into': 'P1'}}
        previous = sys.gettrace()
        try:
            sys.settrace(collector.trace)
            self.assertEqual(kg.canon('P1'), 'P1')
        finally:
            sys.settrace(previous)
        sample = next(iter(collector.samples[function].values()))
        self.assertEqual(sample['input']['self']['fields']['people'], {
            'P1': {'merged_into': 'P2'}, 'P2': {'merged_into': 'P1'},
        })


if __name__ == '__main__':
    unittest.main()
