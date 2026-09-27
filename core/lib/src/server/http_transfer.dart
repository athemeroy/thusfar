part of 'http_server.dart';

extension _Transfers on YeduHttpServer {
  Directory _publish(Directory temporary, String id) {
    final Directory destination = Directory(books.path + '/$id');
    if (!File(destination.path + '/book.json').existsSync()) {
      if (destination.existsSync()) throw const ValueError('书籍目录不完整，请先检查已有文件');
      temporary.renameSync(destination.path);
    }
    return destination;
  }

  Future<void> _upload(_Exchange x) async {
    final String supplied = Uri.decodeComponent(
      x.request.headers.value('x-filename') ?? 'book.txt',
    );
    final String name = _head(supplied.split('/').last, 120);
    final String extension = '.' + name.split('.').last.toLowerCase();
    if (<String>['.mobi', '.azw3', '.azw'].contains(extension))
      return x.error(400, '当前版本支持 TXT、EPUB；MOBI/AZW 请先转成 EPUB');
    if (!<String>['.txt', '.epub'].contains(extension))
      return x.error(400, '支持 TXT、EPUB');
    final Uint8List raw = await x.body(maxUpload);
    if (raw.isEmpty) return x.error(400, '文件是空的');
    final String id = sha1.convert(raw).toString().substring(0, 16);
    final Directory destination = Directory(books.path + '/$id');
    if (File(destination.path + '/book.json').existsSync())
      return x.json(bookSummary(id, destination));
    final Directory temporary = books.createTempSync('.$id.');
    try {
      final String path = temporary.path;
      final HttpJson book = await Isolate.run<HttpJson>(() {
        File(path + '/source$extension').writeAsBytesSync(raw);
        final HttpJson parsed =
            extension == '.txt'
                ? parser.parseTxt(raw, 'source')
                : parseEpubFile(raw, 'source', (String asset, List<int> bytes) {
                  storage.assetName(asset);
                  final File image = File(path + '/img/$asset');
                  image.parent.createSync(recursive: true);
                  image.writeAsBytesSync(bytes);
                });
        if (<Object?>[null, '', 'source'].contains(parsed['title']))
          parsed['title'] =
              name.contains('.')
                  ? name.substring(0, name.lastIndexOf('.'))
                  : name;
        parsed.addAll(<String, Object?>{
          'genre': 'novel',
          'genre_p': 0.0,
          'genre_provisional': true,
        });
        return storage.validateBook(parsed);
      });
      _write(temporary, 'book.json', book);
      _write(temporary, 'meta.json', <String, Object?>{
        'added': _clock(),
        'filename': name,
        'auto': false,
      });
      _write(temporary, 'status.json', <String, Object?>{
        'state': 'idle',
        'done': 0,
        'total': 0,
        'frontier': 0,
      });
      final Directory published = _publish(temporary, id);
      return await x.json(bookSummary(id, published));
    } finally {
      _cache.evict(temporary.path);
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  }

  Future<void> _export(_Exchange x, String id, Directory root) {
    final String before = snapshotVersion(root);
    final Object personal = _read(root, 'notebook.json') ?? <Object?>[],
        manualItems = _read(root, 'manual-entities.json') ?? <Object?>[];
    final HttpJson out = <String, Object?>{
      'format': 'yedu-book/2',
      'exported': _clock(),
      'id': id,
    };
    for (final String part in <String>['book', 'kg', 'meta', 'status']) {
      out[part] = _read(root, '$part.json') ?? <String, Object?>{};
    }
    final Directory folder = Directory(root.path + '/mentions');
    final List<File> files =
        folder.existsSync()
            ? (folder
                .listSync(followLinks: false)
                .whereType<File>()
                .where((File f) => f.path.endsWith('.json'))
                .toList()
              ..sort((File a, File b) => a.path.compareTo(b.path)))
            : <File>[];
    out['mentions'] = <String, Object?>{
      for (final File file in files)
        _name(file).replaceFirst(RegExp(r'\.json$'), ''): read(file),
    };
    out['assets'] = storage.encodeAssets(root, _map(out['book']));
    out['progress'] = _progress[id];
    out['notebook'] = personal;
    out['manual_entities'] = manualItems;
    out['version'] = before;
    if (snapshotVersion(root) != before ||
        !_same(_read(root, 'notebook.json') ?? <Object?>[], personal) ||
        !_same(_read(root, 'manual-entities.json') ?? <Object?>[], manualItems))
      return x.error(409, '这本书正在更新，请稍后重新导出');
    final String title = _head(
      (_map(out['book'])['title'] as String? ?? id).replaceAll(
        pyRe(r'[^\w\u4e00-\u9fff-]+'),
        '_',
      ),
      60,
    );
    final String quoted = Uri.encodeComponent(
      (title.isEmpty ? id : title) + '.yedu.json',
    );
    return x.json(
      out,
      headers: <String, String>{
        'Content-Disposition':
            'attachment; filename="$id.yedu.json"; filename*=UTF-8\'\'$quoted',
      },
    );
  }

  bool _matching(
    Directory root,
    HttpJson book,
    HttpJson graph,
    HttpJson mentions,
    Map<String, Uint8List> assets,
    List<Object?> personal,
    List<HttpJson> manualItems,
  ) {
    if (!_same(_read(root, 'notebook.json') ?? <Object?>[], personal) ||
        !_same(_read(root, 'manual-entities.json') ?? <Object?>[], manualItems))
      return false;
    if (!_same(_read(root, 'book.json'), book) ||
        !_same(
          _read(root, 'kg.json') ?? <String, Object?>{'log': <Object?>[]},
          graph,
        ))
      return false;
    final Directory folder = Directory(root.path + '/mentions');
    final HttpJson actual = <String, Object?>{};
    if (folder.existsSync())
      for (final File file in folder
          .listSync(followLinks: false)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))) {
        actual[int.parse(_name(file).split('.').first).toString()] = read(file);
      }
    if (!_same(actual, <String, Object?>{
      for (final MapEntry<String, Object?> e in mentions.entries)
        int.parse(e.key).toString(): e.value,
    }))
      return false;
    for (final MapEntry<String, Uint8List> e in assets.entries) {
      final File file = File(root.path + '/img/' + e.key);
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !_same(file.readAsBytesSync(), e.value))
        return false;
    }
    return true;
  }

  Future<void> _restore(_Exchange x) async {
    final Uint8List raw = await x.body(maxUpload);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } on FormatException catch (error) {
      return x.error(400, '这个文件不是导出的书：' + error.message);
    }
    if (decoded is! HttpJson) return x.error(400, '导出文件必须是书籍对象');
    final HttpJson payload = decoded;
    if (!<String>['yedu-book/1', 'yedu-book/2'].contains(payload['format']))
      return x.error(400, '认不出的格式：' + pyRepr(payload['format']));
    final HttpJson book = storage.validateBook(payload['book']),
        graph = storage.validateGraph(
          payload['kg'] ?? <String, Object?>{'log': <Object?>[]},
          bookLength(payload['book']),
        );
    final List<Object?> personal = notebook.restore(
      payload['notebook'] ?? <Object?>[],
      book,
      now: _clock,
    );
    final List<HttpJson> manualItems = manual.manualRestore(
      payload['manual_entities'] ?? <Object?>[],
      book,
    );
    if (payload['format'] == 'yedu-book/1' &&
        storage.referencedAssets(book).isNotEmpty)
      throw const ValueError('旧版导出没有包含图片，请从原设备重新导出完整书籍');
    final Map<String, Uint8List> assets = storage.decodeAssets(
      payload['assets'] ?? <String, Object?>{},
      book,
    );
    final Object? rawMentions = payload['mentions'] ?? <String, Object?>{};
    if (rawMentions is! HttpJson ||
        rawMentions.length > _list(book['chapters']).length)
      throw const ValueError('人名索引无效');
    final HttpJson mentions = rawMentions;
    final Set<Object?> known =
        _rows(graph['log'])
            .where((HttpJson row) => row['t'] == 'person')
            .map((HttpJson row) => row['id'])
            .toSet();
    final Set<int> chapters = <int>{};
    for (final MapEntry<String, Object?> e in mentions.entries) {
      final int? index = int.tryParse(e.key);
      if (!RegExp(r'^[0-9]{1,6}$').hasMatch(e.key) ||
          index == null ||
          index >= _list(book['chapters']).length ||
          !chapters.add(index) ||
          e.value is! List)
        throw const ValueError('人名章节索引无效');
      for (final Object? rawRow in e.value! as List<Object?>) {
        if (rawRow is! List<Object?> ||
            rawRow.length < 3 ||
            rawRow[2] is! String ||
            !known.contains(rawRow[2]))
          throw const ValueError('人名索引字段无效');
        final int start = storage.integer(
          rawRow[0],
          '人名起点',
          high: book['len']! as int,
        );
        storage.integer(
          rawRow[1],
          '人名终点',
          low: start,
          high: book['len']! as int,
        );
      }
    }
    HttpJson? progress;
    if (payload['progress'] != null) {
      if (payload['progress'] is! HttpJson) throw const ValueError('阅读进度无效');
      final HttpJson source = payload['progress']! as HttpJson;
      final int length = book['len']! as int,
          pos = storage.integer(source['pos'], '阅读进度', high: length);
      final int cutoff = storage.integer(
        source['cutoff'] ?? pos,
        '已读范围',
        low: pos,
        high: length,
      );
      progress = <String, Object?>{
        'pos': pos,
        'cutoff': cutoff,
        't': _clock(),
        'pct': PyCompat.roundDigits(cutoff / max(1, length) * 100, 3),
      };
    }
    final String id = sha1
        .convert(
          utf8.encode(PyJson.encode(book, ensureAscii: false, sortKeys: true)),
        )
        .toString()
        .substring(0, 16);
    Directory destination = Directory(books.path + '/$id');
    if (File(destination.path + '/book.json').existsSync()) {
      if (!_matching(
        destination,
        book,
        graph,
        mentions,
        assets,
        personal,
        manualItems,
      ))
        return x.error(409, '已有这本书的不同资料，未覆盖；请先保存现有版本后再处理');
      return x.json(bookSummary(id, destination));
    }
    final Directory temporary = books.createTempSync('.$id.');
    try {
      if (payload['meta'] != null && payload['meta'] is! HttpJson)
        throw const ValueError('书籍元数据无效');
      if (payload['status'] != null && payload['status'] is! HttpJson)
        throw const ValueError('整理状态无效');
      final HttpJson meta = <String, Object?>{
        ..._map(payload['meta']),
        'added': _clock(),
        'auto': false,
        'imported': true,
        'hidden': false,
      };
      final HttpJson state = <String, Object?>{..._map(payload['status'])};
      storage.integer(
        state['frontier'] ?? 0,
        '整理进度',
        high: book['len']! as int,
      );
      if (state['state'] != 'done')
        state.addAll(<String, Object?>{
          'state': 'paused',
          'error': null,
          'updated': _clock(),
        });
      for (final (String name, Object value) in <(String, Object)>[
        ('book', book),
        ('kg', graph),
        ('meta', meta),
        ('status', state),
        ('notebook', personal),
        ('manual-entities', manualItems),
      ]) {
        _write(temporary, '$name.json', value);
      }
      for (final MapEntry<String, Object?> e in mentions.entries) {
        _write(
          temporary,
          'mentions/' + int.parse(e.key).toString().padLeft(4, '0') + '.json',
          e.value,
        );
      }
      for (final MapEntry<String, Uint8List> e in assets.entries) {
        final File file = File(temporary.path + '/img/' + e.key);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(e.value);
      }
      final bool existing = File(destination.path + '/book.json').existsSync();
      if (existing &&
          !_matching(
            destination,
            book,
            graph,
            mentions,
            assets,
            personal,
            manualItems,
          ))
        return await x.error(409, '另一份不同的书籍快照刚刚导入，未覆盖已有资料');
      destination = _publish(temporary, id);
      if (progress != null && !existing)
        _write(data, 'progress.json', <String, Object?>{
          ..._progress,
          id: progress,
        });
      return await x.json(bookSummary(id, destination));
    } finally {
      _cache.evict(temporary.path);
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  }
}

int bookLength(Object? raw) => storage.validateBook(raw)['len']! as int;
