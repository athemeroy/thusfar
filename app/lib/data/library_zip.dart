import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'reader_customizations.dart';
import '../reader/text_purification.dart';

/// One portable library file. Each book remains an existing complete single
/// book JSON backup, so native and Web use their established safe merge paths.
const String libraryZipFormat = 'thusfar-library/1';
const int maxLibraryZipBytes = 512 * 1024 * 1024;
const int _maxBookBytes = 144 * 1024 * 1024;
const int _maxSettingsBytes = 64 * 1024;
const int _maxCustomizationsBytes = 1024 * 1024;
const int _maxManifestBytes = 512 * 1024;
const int _maxTotalBytes = 768 * 1024 * 1024;
const int _maxBooks = 2000;

class LibraryZipData {
  const LibraryZipData(this.books, this.settings, {this.customizations});

  final List<Uint8List> books;
  final Map<String, Object?> settings;
  final Map<String, Object?>? customizations;
}

class LibraryZipCodec {
  static Map<String, Object?> validatedSettings(Object? value) =>
      _settings(value);

  static Map<String, Object?> validatedModelProfile(Object? value) {
    final Map<String, Object?> settings = _settings(<String, Object?>{
      'model': value,
    });
    final Object? model = settings['model'];
    if (model is! Map<String, Object?> || model.isEmpty) {
      throw const FormatException('模型配置缺少协议、地址或名称。');
    }
    return model;
  }

  static Uint8List encode({
    required List<Uint8List> books,
    required Map<String, Object?> settings,
    Map<String, Object?>? customizations,
  }) {
    if (books.length > _maxBooks) {
      throw const FormatException('书库超过单个 ZIP 支持的书籍数量。');
    }
    final Map<String, Object?> safeSettings = _settings(settings);
    _validateQueueBounds(safeSettings, books.length);
    final Uint8List settingsBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(safeSettings)),
    );
    if (settingsBytes.length > _maxSettingsBytes) {
      throw const FormatException('书库设置超出备份上限。');
    }
    final Map<String, Object?>? safeCustomizations = customizations == null
        ? null
        : validatedCustomizations(books, customizations);
    final Uint8List? customizationBytes = safeCustomizations == null
        ? null
        : Uint8List.fromList(utf8.encode(jsonEncode(safeCustomizations)));
    if ((customizationBytes?.length ?? 0) > _maxCustomizationsBytes) {
      throw const FormatException('阅读自定义数据超过备份上限。');
    }
    final Archive archive = Archive();
    final List<Map<String, Object?>> records = <Map<String, Object?>>[];
    int total = settingsBytes.length + (customizationBytes?.length ?? 0);
    for (int i = 0; i < books.length; i++) {
      final Uint8List data = books[i];
      if (data.isEmpty || data.length > _maxBookBytes) {
        throw FormatException('第 ${i + 1} 本书超过跨端备份上限。');
      }
      total += data.length;
      if (total > _maxTotalBytes) {
        throw const FormatException('书库超过单个 ZIP 支持的容量。');
      }
      _bookObject(data);
      final String path = 'books/${(i + 1).toString().padLeft(6, '0')}.json';
      archive.addFile(ArchiveFile.bytes(path, data));
      records.add(<String, Object?>{
        'path': path,
        'size': data.length,
        'sha256': sha256.convert(data).toString(),
      });
    }
    archive.addFile(ArchiveFile.bytes('settings.json', settingsBytes));
    if (customizationBytes != null) {
      archive.addFile(
        ArchiveFile.bytes('customizations.json', customizationBytes),
      );
    }
    final Uint8List manifestBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'format': libraryZipFormat,
          'exported_at': DateTime.now().toUtc().toIso8601String(),
          'books': records,
          if (customizationBytes != null)
            'customizations': <String, Object?>{
              'path': 'customizations.json',
              'size': customizationBytes.length,
              'sha256': sha256.convert(customizationBytes).toString(),
            },
          'settings': <String, Object?>{
            'path': 'settings.json',
            'size': settingsBytes.length,
            'sha256': sha256.convert(settingsBytes).toString(),
          },
        }),
      ),
    );
    if (manifestBytes.length > _maxManifestBytes) {
      throw const FormatException('书库清单超出备份上限。');
    }
    total += manifestBytes.length;
    if (total > _maxTotalBytes) {
      throw const FormatException('书库超过单个 ZIP 支持的容量。');
    }
    archive.addFile(ArchiveFile.bytes('manifest.json', manifestBytes));
    final Uint8List zip = ZipEncoder().encodeBytes(archive);
    if (zip.length > maxLibraryZipBytes) {
      throw const FormatException('压缩书库超过单个 ZIP 支持的容量。');
    }
    return zip;
  }

  static LibraryZipData decode(Uint8List zip) {
    if (zip.isEmpty || zip.length > maxLibraryZipBytes) {
      throw const FormatException('书库 ZIP 为空或超过支持的容量。');
    }
    try {
      final int declaredFiles = _preflightCentralDirectory(zip);
      // ZipDecoder eagerly expands Unix symlinks before callers can reject
      // them. Read the central directory directly and decompress each known
      // member into a bounded sink instead.
      final ZipDirectory directory = ZipDirectory()
        ..read(InputMemoryStream(zip));
      final Map<String, ZipFileHeader> files = <String, ZipFileHeader>{};
      if (directory.fileHeaders.length != declaredFiles ||
          directory.fileHeaders.length > _maxBooks + 3) {
        throw const FormatException('书库 ZIP 含有重复或不支持的文件。');
      }
      int total = 0;
      for (final ZipFileHeader header in directory.fileHeaders) {
        final String name = header.filename;
        final bool symlink =
            header.versionMadeBy >> 8 == 3 &&
            ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000;
        if (files.containsKey(name) ||
            name.endsWith('/') ||
            name.endsWith('\\') ||
            symlink ||
            header.file == null ||
            header.file!.filename != name ||
            header.generalPurposeBitFlag & 1 != 0 ||
            header.file!.flags & 1 != 0 ||
            !const <int>{0, 8}.contains(header.compressionMethod) ||
            header.compressedSize < 0 ||
            header.compressedSize > zip.length) {
          throw const FormatException('书库 ZIP 含有重复或不支持的文件。');
        }
        files[name] = header;
        if (header.uncompressedSize < 0 ||
            header.uncompressedSize > _maxBookBytes) {
          throw const FormatException('书库 ZIP 内文件过大。');
        }
        total += header.uncompressedSize;
        if (total > _maxTotalBytes) {
          throw const FormatException('书库 ZIP 解压后超过容量限制。');
        }
      }
      final ZipFileHeader? manifestFile = files['manifest.json'];
      if (manifestFile == null ||
          manifestFile.uncompressedSize > _maxManifestBytes) {
        throw const FormatException('书库 ZIP 缺少清单。');
      }
      final Object? rawManifest = jsonDecode(
        utf8.decode(
          _readBoundedFile(manifestFile, _maxManifestBytes),
          allowMalformed: false,
        ),
      );
      if (rawManifest is! Map<String, Object?> ||
          rawManifest['format'] != libraryZipFormat ||
          rawManifest['books'] is! List<Object?> ||
          rawManifest['settings'] is! Map<String, Object?>) {
        throw const FormatException('书库 ZIP 格式不受支持。');
      }
      final List<Object?> rows = rawManifest['books'] as List<Object?>;
      if (rows.length > _maxBooks ||
          files.length !=
              rows.length +
                  2 +
                  (rawManifest.containsKey('customizations') ? 1 : 0)) {
        throw const FormatException('书库 ZIP 文件数量与清单不符。');
      }
      final Uint8List settingsBytes = _verifiedFile(
        files,
        rawManifest['settings'] as Map<String, Object?>,
        'settings.json',
        _maxSettingsBytes,
      );
      final Object? settingsObject = jsonDecode(
        utf8.decode(settingsBytes, allowMalformed: false),
      );
      final Map<String, Object?> settings = _settings(settingsObject);
      _validateQueueBounds(settings, rows.length);
      final List<Uint8List> books = <Uint8List>[];
      final Set<String> expected = <String>{'manifest.json', 'settings.json'};
      for (int i = 0; i < rows.length; i++) {
        final Object? row = rows[i];
        if (row is! Map<String, Object?>) {
          throw const FormatException('书库 ZIP 书籍清单无效。');
        }
        final String path = 'books/${(i + 1).toString().padLeft(6, '0')}.json';
        final Uint8List data = _verifiedFile(files, row, path, _maxBookBytes);
        _bookObject(data);
        books.add(data);
        expected.add(path);
      }
      Map<String, Object?>? customizations;
      if (rawManifest.containsKey('customizations')) {
        final Object? record = rawManifest['customizations'];
        if (record is! Map<String, Object?>) {
          throw const FormatException('阅读自定义数据清单无效。');
        }
        final Uint8List bytes = _verifiedFile(
          files,
          record,
          'customizations.json',
          _maxCustomizationsBytes,
        );
        customizations = validatedCustomizations(
          books,
          jsonDecode(utf8.decode(bytes, allowMalformed: false)),
        );
        expected.add('customizations.json');
      }
      if (files.keys.any((String name) => !expected.contains(name))) {
        throw const FormatException('书库 ZIP 含有清单外文件。');
      }
      return LibraryZipData(books, settings, customizations: customizations);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('书库 ZIP 无法读取或校验失败，未导入。');
    }
  }

  static Uint8List _verifiedFile(
    Map<String, ZipFileHeader> files,
    Map<String, Object?> record,
    String path,
    int limit,
  ) {
    final ZipFileHeader? file = files[path];
    if (record['path'] != path ||
        record['size'] is! int ||
        record['sha256'] is! String ||
        file == null ||
        file.uncompressedSize != record['size'] ||
        file.uncompressedSize < 0 ||
        file.uncompressedSize > limit) {
      throw const FormatException('书库 ZIP 文件与清单不符。');
    }
    final Uint8List data = _readBoundedFile(file, limit);
    if (data.length != file.uncompressedSize ||
        sha256.convert(data).toString() != record['sha256']) {
      throw const FormatException('书库 ZIP 校验失败，未导入。');
    }
    return data;
  }

  static Uint8List _readBoundedFile(ZipFileHeader header, int limit) {
    final InputStream raw = header.file!.getStream(decompress: false);
    raw.setPosition(0);
    if (raw.length != header.compressedSize) {
      throw const FormatException('书库 ZIP 压缩数据不完整。');
    }
    if (header.compressionMethod == 0) {
      if (raw.length > limit) {
        throw const FormatException('书库 ZIP 内文件过大。');
      }
      return raw.toUint8List();
    }
    final _BoundedOutput output = _BoundedOutput(
      header.uncompressedSize < limit ? header.uncompressedSize : limit,
    );
    Inflate.stream(raw, output: output);
    return output.getBytes();
  }

  static int _preflightCentralDirectory(Uint8List zip) {
    // Standard EOCD is at the tail, with at most a 64 KiB comment. Our
    // portable format does not need multi-disk or ZIP64 archives.
    final ByteData bytes = ByteData.sublistView(zip);
    final int first = zip.length - 22 - 65535 < 0 ? 0 : zip.length - 22 - 65535;
    for (int pos = zip.length - 22; pos >= first; pos--) {
      if (bytes.getUint32(pos, Endian.little) != 0x06054b50 ||
          pos + 22 + bytes.getUint16(pos + 20, Endian.little) != zip.length) {
        continue;
      }
      final int entries = bytes.getUint16(pos + 10, Endian.little);
      final int size = bytes.getUint32(pos + 12, Endian.little);
      final int offset = bytes.getUint32(pos + 16, Endian.little);
      if (bytes.getUint16(pos + 4, Endian.little) != 0 ||
          bytes.getUint16(pos + 6, Endian.little) != 0 ||
          bytes.getUint16(pos + 8, Endian.little) != entries ||
          entries < 2 ||
          entries > _maxBooks + 3 ||
          size <= 0 ||
          size > 2 * 1024 * 1024 ||
          offset > pos ||
          size > pos - offset) {
        throw const FormatException('书库 ZIP 目录超出支持范围。');
      }
      return entries;
    }
    throw const FormatException('书库 ZIP 目录缺失或格式无效。');
  }

  static void _bookObject(Uint8List data) {
    final Object? value = jsonDecode(utf8.decode(data, allowMalformed: false));
    if (value is! Map<String, Object?> ||
        !const <String>{
          'yedu-book/2',
          'thusfar-web-backup-v1',
        }.contains(value['format']) ||
        value['book'] is! Map<String, Object?>) {
      throw const FormatException('书库 ZIP 中包含无效的单书备份。');
    }
  }

  /// Bind full-library rule policy to the copies embedded in each book. The
  /// payload may be a subset after Web adds new books; it cannot contradict a
  /// represented book's scoped rules or silently choose one conflicting copy.
  static Map<String, Object?> validatedCustomizations(
    List<Uint8List> books,
    Object? value,
  ) {
    final Map<String, Object?> result = validatedReaderLibrary(
      value,
      sources: _customizationSources(books),
    );
    final Set<String> represented = <String>{
      for (final Object? row in result['books']! as List<Object?>)
        (row! as Map<String, Object?>)['bookId']! as String,
    };
    final List<PurificationRule> rules = decodeReaderPurificationRules(
      result['purification'],
    );
    for (final Uint8List bytes in books) {
      final Map<String, Object?> wrapper =
          jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      final Object? native = wrapper['format'] == 'thusfar-web-backup-v1'
          ? wrapper['native_backup']
          : wrapper;
      if (native is! Map<String, Object?> ||
          !represented.contains(native['id'])) {
        continue;
      }
      final String id = native['id']! as String;
      final Map<String, Object?>? custom = validatedReaderCustomizations(
        native['reader_customizations'],
        book: wrapper['book']! as Map<String, Object?>,
        bookId: id,
        meta: native['meta'] is Map<String, Object?>
            ? native['meta']! as Map<String, Object?>
            : <String, Object?>{},
      );
      final Object scoped = encodeReaderPurificationRules(
        rules.where((rule) => rule.bookId == id),
      );
      final Object embedded = custom?['purification'] ?? <Object?>[];
      if (jsonEncode(scoped) != jsonEncode(embedded)) {
        throw const FormatException('整库规则与单书规则副本不同，未导入。');
      }
    }
    return result;
  }

  static Map<String, String> _customizationSources(List<Uint8List> books) {
    final Map<String, String> result = <String, String>{};
    for (final Uint8List bytes in books) {
      final Map<String, Object?> wrapper =
          jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      final Object? native = wrapper['format'] == 'thusfar-web-backup-v1'
          ? wrapper['native_backup']
          : wrapper;
      if (native is! Map<String, Object?> || native['id'] is! String) continue;
      final String id = native['id']! as String;
      final String source = readerCustomizationSource(
        wrapper['book']! as Map<String, Object?>,
      );
      if (result.containsKey(id)) {
        throw const FormatException('书库含有重复的阅读自定义书籍编号。');
      }
      result[id] = source;
    }
    return result;
  }

  static void _validateQueueBounds(Map<String, Object?> settings, int count) {
    final Object? shelf = settings['shelf'];
    if (shelf is! Map<String, Object?>) return;
    final Object? queue = shelf['readingQueue'];
    if (queue is List<int> && queue.any((int index) => index >= count)) {
      throw const FormatException('书库 ZIP 阅读清单引用了不存在的书籍。');
    }
  }

  static Map<String, Object?> _settings(Object? value) {
    if (value is! Map<String, Object?> ||
        value.keys.any(
          (String key) => !const <String>{
            'reader',
            'native',
            'web',
            'model',
            'shelf',
          }.contains(key),
        )) {
      throw const FormatException('书库 ZIP 设置格式无效。');
    }
    final Map<String, Object?> result = <String, Object?>{};
    const Map<String, Set<String>> allowed = <String, Set<String>>{
      'reader': <String>{
        'fontSize',
        'lineHeight',
        'letterSpacing',
        'margin',
        'paper',
        'font',
        'pageMode',
        'columnWidth',
      },
      'native': <String>{
        'spacing',
        'pageHorizontalMargin',
        'pageVerticalMargin',
        'anim',
        'volumeKeys',
        'night',
        'sort',
        'listView',
        'tapLayout',
        'paragraphSpacing',
        'firstLineIndent',
      },
      'web': <String>{'pageMode', 'columnWidth', 'fontSize'},
      'model': <String>{
        'protocol',
        'base_url',
        'model',
        'jev_route',
        'judge_url',
        'judge_model',
      },
      'shelf': <String>{'readingQueue'},
    };
    for (final String section in allowed.keys) {
      final Object? raw = value[section];
      if (raw == null) continue;
      if (raw is! Map<String, Object?> ||
          raw.keys.any((String key) => !allowed[section]!.contains(key))) {
        throw const FormatException('书库 ZIP 设置包含不支持的字段。');
      }
      final Map<String, Object?> safe = <String, Object?>{};
      for (final MapEntry<String, Object?> entry in raw.entries) {
        final Object? field = entry.value;
        if (section == 'native' && entry.key == 'tapLayout') {
          if (field is! List<Object?> ||
              field.length != 9 ||
              field[4] != 'tools' ||
              field.any(
                (Object? action) => !const <String>{
                  'previous',
                  'tools',
                  'next',
                  'none',
                }.contains(action),
              )) {
            throw const FormatException('书库 ZIP 点击区域设置无效。');
          }
          safe[entry.key] = List<String>.of(field.cast<String>());
          continue;
        }
        if (section == 'shelf' && entry.key == 'readingQueue') {
          if (field is! List<Object?> ||
              field.length > _maxBooks ||
              field.any(
                (Object? index) =>
                    index is! int || index < 0 || index >= _maxBooks,
              ) ||
              field.toSet().length != field.length) {
            throw const FormatException('书库 ZIP 阅读清单无效。');
          }
          safe[entry.key] = List<int>.of(field.cast<int>());
          continue;
        }
        if (field is num && field.isFinite ||
            field is bool ||
            field is String && field.length <= 2048) {
          _validateSettingField(section, entry.key, field);
          safe[entry.key] = field;
        } else {
          throw const FormatException('书库 ZIP 设置值无效。');
        }
      }
      result[section] = safe;
    }
    final Object? model = result['model'];
    if (model is Map<String, Object?> && model.isNotEmpty) {
      final Object? protocol = model['protocol'];
      final Object? url = model['base_url'];
      final Object? name = model['model'];
      final Object? route = model['jev_route'];
      if (!const <String>{'openai', 'gemini', 'anthropic'}.contains(protocol) ||
          url is! String ||
          name is! String ||
          route != null &&
              !const <String>{
                'free-only',
                'free-then-model',
                'systemone',
                'model',
              }.contains(route) ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/+:-]{0,99}$').hasMatch(name)) {
        throw const FormatException('书库 ZIP 模型配置无效。');
      }
      final Object? judgeModel = model['judge_model'];
      if (judgeModel != null &&
          (judgeModel is! String ||
              judgeModel.isNotEmpty &&
                  !RegExp(
                    r'^[A-Za-z0-9][A-Za-z0-9._/+:-]{0,99}$',
                  ).hasMatch(judgeModel))) {
        throw const FormatException('书库 ZIP 核对模型名称无效。');
      }
      final Object? judgeUrl = model['judge_url'];
      if (judgeUrl != null && judgeUrl is! String) {
        throw const FormatException('书库 ZIP 核对地址无效。');
      }
      for (final String address in [
        url,
        if (judgeUrl is String && judgeUrl.isNotEmpty) judgeUrl,
      ]) {
        final Uri? uri = Uri.tryParse(address);
        final bool loopback =
            uri != null &&
            const <String>{
              'localhost',
              '127.0.0.1',
              '::1',
            }.contains(uri.host.toLowerCase());
        if (uri == null ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            !(uri.scheme == 'https' || loopback && uri.scheme == 'http')) {
          throw const FormatException('书库 ZIP 模型地址含有敏感或无效内容。');
        }
      }
    }
    return result;
  }

  static void _validateSettingField(String section, String key, Object? value) {
    if (section == 'model') return;
    if (key == 'pageMode' || key == 'volumeKeys' || key == 'listView') {
      if (value is! bool) throw const FormatException('书库 ZIP 开关设置无效。');
      return;
    }
    if (value is! num || !value.isFinite) {
      throw const FormatException('书库 ZIP 排版数字无效。');
    }
    const Map<String, (double, double)> ranges = <String, (double, double)>{
      'fontSize': (14, 34),
      'lineHeight': (1.2, 2.4),
      'letterSpacing': (-0.5, 2.5),
      'margin': (8, 96),
      'columnWidth': (520, 1400),
      'pageHorizontalMargin': (8, 96),
      'pageVerticalMargin': (4, 48),
      'paper': (0, 4),
      'font': (0, 2),
      'spacing': (0, 2),
      'anim': (0, 2),
      'night': (0, 2),
      'sort': (0, 3),
      'paragraphSpacing': (0, 2),
      'firstLineIndent': (0, 4),
    };
    final (double, double)? range = ranges[key];
    if (range == null ||
        value < range.$1 ||
        value > range.$2 ||
        <String>{
              'paper',
              'font',
              'spacing',
              'anim',
              'night',
              'sort',
            }.contains(key) &&
            value.toInt() != value) {
      throw const FormatException('书库 ZIP 排版设置超出范围。');
    }
  }
}

/// Bounds every Inflate write, including LZ77 back references. This applies
/// in the browser too; archive's Web ZLibDecoder buffers before writing to its
/// caller's sink and cannot enforce a limit itself.
class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit) : super(size: 32 * 1024);

  final int limit;

  void _requireCapacity(int count) {
    if (count < 0 || length + count > limit) {
      throw const FormatException('书库 ZIP 解压后超过容量限制。');
    }
  }

  @override
  void writeByte(int value) {
    _requireCapacity(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _requireCapacity(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _requireCapacity(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _requireCapacity(count);
    super.writeBackReference(distance, count);
  }
}
