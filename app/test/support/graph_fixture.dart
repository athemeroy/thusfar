import 'dart:io';

import 'package:flutter/material.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';

class GraphFixture {
  GraphFixture({bool longNames = false}) {
    directory = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    final Json book = <String, Object?>{
      'title': '关系图示例',
      'lang': 'zh',
      'len': 1000,
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{
          'k': 'p',
          't': ('林小明与老师谈起过去。' * 100).substring(0, 1000),
          'o': 0,
        },
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': '第一章',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': 1000,
          'kind': 'body',
        },
      ],
    };
    writeJson(File('${directory.path}/book.json'), book);
    records = <Json>[
      <String, Object?>{
        't': 'person',
        'id': 'P1',
        'name': longNames ? '来自远方的林先生' : '林先生',
        'p': 0,
      },
      <String, Object?>{
        't': 'person',
        'id': 'P2',
        'name': longNames ? '正在学习医术的小明' : '小明',
        'p': 0,
      },
      <String, Object?>{
        't': 'rel',
        'a': 'P1',
        'b': 'P2',
        'a_is': '导师',
        'b_is': '学生',
        'desc': '林先生指导小明学习医术。',
        'p': 20,
      },
      <String, Object?>{
        't': 'rel',
        'a': 'P1',
        'b': 'P2',
        'a_is': longNames ? '曾经共同研究草药医理的导师' : '前导师',
        'b_is': longNames ? '后来离开故乡继续独立求学的学生' : '前学生',
        'desc': description,
        'status': 'ended',
        'p': 700,
      },
    ];
    writeJson(File('${directory.path}/kg.json'), <String, Object?>{
      'log': records,
    });
    writeJson(File('${directory.path}/status.json'), <String, Object?>{
      'state': 'done',
      'frontier': 1000,
    });
    library = Library(root);
    entry = BookEntry(
      id: 'fixture',
      dir: directory,
      meta: book,
      status: const ProcessStatus(<String, Object?>{
        'state': 'done',
        'frontier': 1000,
      }),
      added: 0,
    );
    library.books.add(entry);
    data = BookData.open(entry);
    controller = ReaderController(library: library, book: data);
    controller.layout(
      Paginator(
        data,
        const PageSpec(
          width: 280,
          height: 220,
          fontSize: 16,
          lineHeight: 1.6,
          fontFamily: null,
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      ),
      0,
    );
    setCutoff(1000, notify: false);
    link = ReaderLink(
      c: controller,
      jump: (int _, {(int, int)? highlight}) {},
      openAsk: ({String? prefill, String? quote}) {},
    );
    SeenStore.instance.attach(File('${root.path}/seen.json'));
  }

  static const String description =
      '小明离开故乡以后，两人结束了正式的师生关系，但仍然通信讨论草药与医理。这段说明应能在关系详情中完整阅读，不能因图上的标签宽度有限而丢失。';
  final Directory root = Directory.systemTemp.createTempSync(
    'thusfar-graph-ui-',
  );
  late Directory directory;
  late Library library;
  late BookEntry entry;
  late List<Json> records;
  late BookData data;
  late ReaderController controller;
  late ReaderLink link;

  void setCutoff(int cutoff, {bool notify = true}) {
    controller.page = PageData(
      chapter: 0,
      index: 0,
      frags: <Frag>[],
      start: 0,
      end: cutoff,
    );
    if (notify) controller.touch();
  }

  void refresh() {
    writeJson(File('${directory.path}/kg.json'), <String, Object?>{
      'log': records,
    });
    library.refreshStatus(entry);
    data.refreshKnowledge();
  }

  void dispose() {
    controller.dispose();
    data.notes.dispose();
    data.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  }
}
