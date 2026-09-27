part of 'http_server.dart';

extension _BookEndpoints on YeduHttpServer {
  Directory? bookDirectory(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) return null;
    final Directory root = Directory(books.path + '/$id');
    return File(root.path + '/book.json').existsSync() ? root : null;
  }

  HttpJson get _progress => _jsonFile(data, 'progress.json');
  HttpJson bookSummary(String id, Directory root) {
    final HttpJson book = storage.shelfFields(_jsonFile(root, 'book.json')),
        state = _jsonFile(root, 'status.json'),
        meta = _jsonFile(root, 'meta.json');
    final (String title, String author) = storage.displayTitle(
      book['title'] as String?,
      book['author'] as String?,
    );
    final (double, double)? cost =
        state['state'] == 'done' || _truth(state['done'])
            ? models.costOf(_map(state['usage']))
            : null;
    return <String, Object?>{
      'id': id,
      'title': title,
      'author': author,
      'len': book['len'],
      'cover': _truth(book['cover']) ? book['cover'] : meta['cover'],
      'added': meta['added'] ?? 0,
      'status': state,
      'chapters': book['chapters'],
      'auto': _truth(meta['auto']),
      'lang': book['lang'] ?? 'zh',
      'genre': book['genre'] ?? 'novel',
      'thin': book['thin'],
      'est': models.estimate(
        (book['len'] as int?) ?? 0,
        lang: (book['lang'] as String?) ?? 'zh',
      ),
      'spent': cost == null ? null : <double>[cost.$1, cost.$2],
      'progress': _progress[id],
    };
  }

  String bookRevision(Directory root) =>
      sha256
          .convert(File(root.path + '/book.json').readAsBytesSync())
          .toString();
  String snapshotVersion(Directory root) {
    final List<File> files = <File>[
      for (final String name in <String>['book', 'kg', 'status'])
        File(root.path + '/$name.json'),
    ];
    for (final String sub in <String>['mentions', 'img']) {
      final Directory folder = Directory(root.path + '/$sub');
      if (folder.existsSync())
        files.addAll(
          folder.listSync(followLinks: false).whereType<File>().toList()
            ..sort((File a, File b) => a.path.compareTo(b.path)),
        );
    }
    return _hash(<Object?>[
      for (final File file in files)
        if (file.existsSync())
          <Object?>[
            file.path.substring(root.path.length + 1),
            sha256.convert(file.readAsBytesSync()).toString(),
          ],
    ]);
  }

  Future<void> _bookRoute(
    _Exchange x,
    String id,
    Directory root,
    String rest,
  ) async {
    final String method = x.method;
    final Map<String, String> query = x.request.uri.queryParameters;
    if (rest.isEmpty && method == 'GET') {
      final HttpJson book = _jsonFile(root, 'book.json');
      final (String title, String author) = storage.displayTitle(
        book['title'] as String?,
        book['author'] as String?,
      );
      return x.json(<String, Object?>{
        'id': id,
        'title': title,
        'author': author,
        'len': book['len'],
        'version': bookRevision(root),
        'lang': language.bookLang(book),
        'genre': book['genre'] ?? 'novel',
        'thin': storage.shelfFields(book)['thin'],
        'chapters': <HttpJson>[
          for (final HttpJson c in _rows(book['chapters']))
            <String, Object?>{
              for (final String key in <String>[
                'title',
                'depth',
                'parent',
                'o0',
                'o1',
                'kind',
                'spoil',
              ])
                key: c[key],
            },
        ],
        'status': _jsonFile(root, 'status.json'),
        'progress': _progress[id],
      });
    }
    if (rest.isEmpty && method == 'DELETE') {
      await worker.pauseBook(root);
      await worker.waitBookIdle(root);
      await bookLease<void>(root, () {
        final Directory trash = Directory(data.path + '/trash')
          ..createSync(recursive: true);
        final Directory destination = Directory(
          trash.path + '/$id-' + (_clock() * 1e9).toInt().toString(),
        );
        root.renameSync(destination.path);
        final HttpJson progress = <String, Object?>{..._progress};
        final Object? previous = progress.remove(id);
        if (previous != null)
          _write(destination, 'reading-progress.json', previous);
        _write(data, 'progress.json', progress);
        _cache.evict(root.path);
      });
      return x.json(<String, Object?>{'ok': true});
    }
    if (rest == '/export' && method == 'GET') return _export(x, id, root);
    if (rest == '/offline-manifest' && method == 'GET')
      return _offlineManifest(x, id, root);
    final RegExpMatch? chapter = RegExp(
      r'^/chapters/([0-9]+)$',
    ).firstMatch(rest);
    if (chapter != null && method == 'GET')
      return _chapter(x, root, int.parse(chapter[1]!));
    if (rest == '/kg' && method == 'GET') return _graph(x, root, query);
    if (rest == '/manual-entities' && <String>['GET', 'PUT'].contains(method)) {
      final HttpJson? payload = method == 'PUT' ? await x.object() : null;
      final List<HttpJson> current = _rows(_read(root, 'manual-entities.json'));
      final HttpJson book = _jsonFile(root, 'book.json');
      if (payload == null) {
        final int cutoff = storage.integer(
          _queryInt(query['to'], 0, '已读范围无效'),
          '已读范围',
          high: book['len']! as int,
        );
        return x.json(<String, Object?>{
          'items': <HttpJson>[
            for (final HttpJson item in current)
              if (!_truth(item['deleted']) &&
                  (_rows(item['versions']).first['p']! as num) <= cutoff)
                <String, Object?>{
                  ...item,
                  'versions':
                      _rows(item['versions'])
                          .where((HttpJson v) => (v['p']! as num) <= cutoff)
                          .toList(),
                  'locked': (item['knowledge_cutoff']! as num) > cutoff,
                },
          ],
        });
      }
      final (List<HttpJson> updated, HttpJson? item, bool conflict) = manual
          .manualApply(
            current,
            payload,
            book,
            _jsonFile(root, 'kg.json'),
            clock: _clock,
          );
      if (conflict)
        return x.json(<String, Object?>{
          'error': '这条资料已在其他设备修改',
          'item': item,
        }, code: 409);
      if (!identical(updated, current))
        _write(root, 'manual-entities.json', updated);
      return x.json(<String, Object?>{'item': item});
    }
    if (rest == '/notebook' && <String>['GET', 'PUT'].contains(method)) {
      final HttpJson? payload = method == 'PUT' ? await x.object() : null;
      final List<Object?> current = _list(_read(root, 'notebook.json'));
      if (payload == null) return x.json(<String, Object?>{'items': current});
      final (List<Object?> updated, HttpJson? item, bool conflict) = notebook
          .apply(current, payload, _jsonFile(root, 'book.json'), now: _clock);
      if (conflict)
        return x.json(<String, Object?>{
          'error': '这条摘记已在其他设备修改',
          'item': item,
        }, code: 409);
      if (!identical(updated, current)) _write(root, 'notebook.json', updated);
      return x.json(<String, Object?>{'item': item});
    }
    if (rest == '/notebook.md' && method == 'GET') {
      final List<String> lines = <String>[
        '# ' + (_jsonFile(root, 'book.json')['title'] as String? ?? id),
        '',
        '个人摘记（包含全书已保存的摘记）',
        '',
      ];
      final List<HttpJson> items =
          _rows(_read(root, 'notebook.json')).toList()..sort(
            (HttpJson a, HttpJson b) =>
                (a['start']! as int).compareTo(b['start']! as int),
          );
      for (final HttpJson item in items) {
        if (_truth(item['deleted'])) continue;
        lines.addAll(<String>[
          '## ' +
              (item['kind'] == 'bookmark' ? '书签' : '摘记') +
              ' · 原文位置 ' +
              item['start'].toString(),
          '',
        ]);
        lines.addAll(
          parser
              .splitlines(item['quote']! as String)
              .map((String line) => '> $line'),
        );
        lines.addAll(<String>[
          '',
          item['text']! as String,
          '',
          '[回到书中](/#/read/$id?at=' + item['start'].toString() + ')',
          '',
        ]);
      }
      return x.send(
        200,
        utf8.encode(lines.join('\n')),
        'text/markdown; charset=utf-8',
        headers: <String, String>{
          'Content-Disposition': 'attachment; filename="$id-notes.md"',
          'Cache-Control': 'no-store',
        },
      );
    }
    if (rest == '/progress' && <String>['POST', 'PUT'].contains(method)) {
      final HttpJson payload = await x.object();
      final int length = _jsonFile(root, 'book.json')['len']! as int;
      final int pos = storage.integer(
        payload['pos'] ?? 0,
        '阅读位置',
        high: length,
      );
      final int cutoff = storage.integer(
        payload['cutoff'] ?? pos,
        '已读范围',
        low: pos,
        high: length,
      );
      final HttpJson progress = <String, Object?>{..._progress};
      final Object? current = progress[id];
      if (payload.containsKey('expected_t') &&
          payload['expected_t'] != _map(current)['t'])
        return x.json(<String, Object?>{
          'error': '阅读进度已在其他设备更新',
          'progress': current,
        }, code: 409);
      progress[id] = <String, Object?>{
        'pos': pos,
        'cutoff': cutoff,
        't': _clock(),
        'pct': PyCompat.roundDigits(cutoff / max(1, length) * 100, 3),
      };
      _write(data, 'progress.json', progress);
      return x.json(<String, Object?>{'ok': true, 'progress': progress[id]});
    }
    if (rest == '/kind' && method == 'PUT') {
      final Object? raw = (await x.object())['kind'];
      if (raw is! String) throw const ValueError('书籍类型无效');
      final String kind = raw.trim();
      if (!<String>{
        'novel',
        'biography',
        'collection',
        'nonfiction',
        'reference',
      }.contains(kind))
        return x.error(400, '不认识这个类型');
      await bookLease<void>(root, () {
        final HttpJson book = <String, Object?>{
          ..._jsonFile(root, 'book.json'),
          'genre': kind,
          'genre_p': 1.0,
          'genre_provisional': false,
        };
        _write(root, 'book.json', book);
      });
      return x.json(<String, Object?>{'ok': true, 'genre': kind});
    }
    if (rest == '/process' && <String>['POST', 'DELETE'].contains(method)) {
      if (method == 'POST') {
        if (localMode && !_truth(settings.read()['api_key']))
          return x.error(409, '还没有填写模型 API 密钥，请先到「模型设置」填写');
        await worker.startBook(root);
      } else {
        await worker.pauseBook(root);
      }
      return x.json(<String, Object?>{
        'ok': true,
        'status': _read(root, 'status.json'),
      });
    }
    if (rest == '/who' && method == 'POST') {
      final HttpJson payload = await x.object(),
          book = _jsonFile(root, 'book.json');
      final int pos = storage.integer(
        payload['pos'] ?? 0,
        '阅读位置',
        high: book['len']! as int,
      );
      final int start = storage.integer(
        payload['start'] ?? pos,
        '选中位置',
        high: pos,
      );
      final int end = storage.integer(
        payload['end'] ?? start + 1,
        '选中终点',
        low: start,
        high: pos,
      );
      final List<HttpJson> log = _rows(_jsonFile(root, 'kg.json')['log']);
      return _ai(
        x,
        () =>
            _map(foldEvidence(log, pos)['people']).isEmpty
                ? Future<HttpJson>.value(<String, Object?>{
                  'ok': false,
                  'why': 'nobody yet',
                })
                : _who(book, log, pos, start, end),
        '正在回答其他问题，请稍后重试',
      );
    }
    if (rest == '/marginalia' && method == 'POST') {
      final HttpJson payload = await x.object();
      return _comment(x, root, payload);
    }
    if (rest == '/ask' && method == 'POST')
      return _answer(x, root, await x.object());
    final RegExpMatch? img = RegExp(
      r'^/img/([A-Za-z0-9_.-]+)$',
    ).firstMatch(rest);
    if (img != null && method == 'GET') {
      final File file = File(root.path + '/img/' + img[1]!);
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file)
        return x.error(404, '没有这张图');
      return x.send(
        200,
        file.readAsBytesSync(),
        _mime(file.path),
        headers: <String, String>{
          'Cache-Control': 'private, max-age=31536000, immutable',
          'Content-Security-Policy': "default-src 'none'; sandbox",
        },
      );
    }
    return x.error(404, '没有这个接口');
  }

  Future<void> _chapter(_Exchange x, Directory root, int n) {
    final HttpJson book = _jsonFile(root, 'book.json');
    final List<HttpJson> chapters = _rows(book['chapters']);
    if (n < 0 || n >= chapters.length) return x.error(404, '没有这一章');
    final HttpJson c = chapters[n];
    final List<HttpJson> blocks = _rows(
      book['blocks'],
    ).sublist(c['b0']! as int, c['b1']! as int);
    final num frontier =
        (_jsonFile(root, 'status.json')['frontier'] as num?) ?? 0;
    List<List<Object?>> mentions =
        _list(_read(root, 'mentions/' + n.toString().padLeft(4, '0') + '.json'))
            .cast<List<Object?>>()
            .where((List<Object?> m) => (m[1]! as num) <= frontier)
            .toList();
    final List<HttpJson> personal = _rows(_read(root, 'manual-entities.json'));
    if (personal.isNotEmpty)
      mentions = manual.manualMentions(blocks, personal, mentions);
    final HttpJson notes = <String, Object?>{};
    for (final HttpJson block in blocks) {
      for (final Object? raw in _list(block['fn'])) {
        final List<Object?> item = raw! as List<Object?>;
        notes[item[1]! as String] = _map(book['notes'])[item[1]] ?? '';
      }
    }
    return x.json(
      <String, Object?>{
        'n': n,
        'title': c['title'],
        'parent': c['parent'],
        'kind': c['kind'],
        'o0': c['o0'],
        'o1': c['o1'],
        'blocks': blocks,
        'mentions': mentions,
        'notes': notes,
      },
      headers: <String, String>{'Cache-Control': 'private, no-cache'},
    );
  }

  Future<void> _graph(_Exchange x, Directory root, Map<String, String> query) {
    final int hi = _queryInt(query['to'], 0, '位置不对'),
        lo = _queryInt(query['from'], -1, '位置不对');
    final List<HttpJson> log = <HttpJson>[
      ..._rows(_jsonFile(root, 'kg.json')['log']),
      ...manual.manualRows(_rows(_read(root, 'manual-entities.json'))),
    ];
    final List<HttpJson> sorted = PyCompat.stableSorted<HttpJson>(
      log,
      key: (HttpJson row) => row['p'],
    );
    final HttpJson state = _jsonFile(root, 'status.json');
    return x.json(<String, Object?>{
      'from': lo,
      'to': hi,
      'frontier': state['frontier'] ?? 0,
      'state': state['state'],
      'before': sorted.where((HttpJson row) => (row['p']! as num) <= lo).length,
      'records':
          sorted
              .where(
                (HttpJson row) =>
                    (row['p']! as num) > lo && (row['p']! as num) <= hi,
              )
              .toList(),
    });
  }

  Future<void> _offlineManifest(_Exchange x, String id, Directory root) {
    final HttpJson book = _jsonFile(root, 'book.json'),
        state = _jsonFile(root, 'status.json');
    final String base = '/api/books/$id';
    final List<HttpJson> chapters = <HttpJson>[];
    final List<HttpJson> blocks = _rows(book['blocks']);
    for (final (int i, HttpJson c) in _rows(book['chapters']).indexed) {
      chapters.add(<String, Object?>{
        'n': i,
        'url': '$base/chapters/$i',
        'images': <String>[
          for (final HttpJson b in blocks.sublist(
            c['b0']! as int,
            c['b1']! as int,
          ))
            if (b['k'] == 'img') '$base/img/' + (b['src']! as String),
        ],
      });
    }
    final HttpJson metadata = <String, Object?>{
      for (final String key in <String>[
        'title',
        'author',
        'len',
        'lang',
        'genre',
        'chapters',
        'cover',
      ])
        key: book[key],
      'id': id,
      'status': state,
      'progress': _progress[id],
      'version': bookRevision(root),
    };
    final String version = _hash(<Object?>[
      snapshotVersion(root),
      _read(root, 'notebook.json'),
      _read(root, 'manual-entities.json'),
    ]);
    final List<String> assets = storage.referencedAssets(book).toList()..sort();
    return x.json(<String, Object?>{
      'version': version,
      'book': metadata,
      'chapters': chapters,
      'notebook': <String, Object?>{'url': '$base/notebook'},
      'assets': assets.map((String name) => '$base/img/$name').toList(),
      'graph': <String, Object?>{
        'url': '$base/kg?from=-1&to=' + book['len'].toString(),
        'to': book['len'],
      },
      'frontier': state['frontier'] ?? 0,
      'state': state['state'],
    });
  }

  Future<void> _ai(
    _Exchange x,
    Future<HttpJson> Function() invoke,
    String busy,
  ) async {
    if (!_askGate.tryAcquire()) return x.error(429, busy);
    final Future<HttpJson> operation = Future<HttpJson>.sync(invoke);
    unawaited(
      operation.then<void>(
        (_) => _askGate.release(),
        onError: (Object _, StackTrace __) => _askGate.release(),
      ),
    );
    return x.json(await operation.timeout(answerTimeout));
  }

  Future<void> _answer(_Exchange x, Directory root, HttpJson payload) async {
    if (!_askGate.tryAcquire()) return x.error(429, '正在回答其他问题，请稍后重试');
    bool handedOff = false;
    try {
      if (payload['q'] is! String) throw const ValueError('问题必须是文字');
      final String question = _head((payload['q']! as String).trim(), 500);
      final int pos = storage.integer(
        payload['pos'] ?? 0,
        '阅读位置',
        high: _jsonFile(root, 'book.json')['len']! as int,
      );
      if (question.isEmpty) throw const ValueError('问题是空的');
      final HttpResponse response = x.request.response;
      response.statusCode = 200;
      response.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
      response.headers.set('Cache-Control', 'no-store');
      response.persistentConnection = false;
      x.sent = true;
      final ask.AskCancellation cancellation = ask.AskCancellation();
      unawaited(
        response.done.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {
            cancellation.cancel();
          },
        ),
      );
      Future<void> output = Future<void>.value();
      void emit(String kind, HttpJson value) {
        if (kind != 'error') cancellation.check();
        final String frame =
            'event: $kind\ndata: ' +
            PyJson.encode(value, ensureAscii: false) +
            '\n\n';
        output = output
            .then<void>((_) async {
              response.write(frame);
              await response.flush();
            })
            .catchError((Object _) {
              cancellation.cancel();
            });
      }

      final Future<HttpJson> operation = askService.answer(
        root,
        question,
        pos,
        onEvent: emit,
        cancellation: cancellation,
        onSettled: _askGate.release,
      );
      handedOff = true;
      try {
        await operation.timeout(answerTimeout);
      } on Object catch (error, stack) {
        onError?.call(error, stack);
        try {
          emit('error', <String, Object?>{
            'message': '出错了：' + _head(_message(error), 120),
          });
        } on Object {
          /*disconnected*/
        }
      }
      await output;
      cancellation.cancel();
      await response.close();
    } finally {
      if (!handedOff) _askGate.release();
    }
  }

  Future<void> _comment(_Exchange x, Directory root, HttpJson payload) async {
    if (_marginalia != null)
      return _ai(x, () => _marginalia(root, payload), 'AI 正在写另一条批注，请稍后再试');
    if (!_askGate.tryAcquire()) return x.error(429, 'AI 正在写另一条批注，请稍后再试');
    final marginalia.MarginaliaCancellation cancellation =
        marginalia.MarginaliaCancellation();
    final Future<HttpJson> operation = marginaliaService.respond(
      root,
      payload,
      cancellation: cancellation,
      onSettled: _askGate.release,
    );
    final HttpJson result = await operation.timeout(
      answerTimeout,
      onTimeout: () {
        cancellation.cancel();
        throw TimeoutException('批注超时，请稍后重试');
      },
    );
    return x.json(result);
  }
}
