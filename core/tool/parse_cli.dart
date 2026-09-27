// Parses one TXT/EPUB and prints book.json: dart run tool/parse_cli.dart FILE
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:thusfar_core/src/pipeline/epub.dart';
import 'package:thusfar_core/src/pipeline/parse.dart';

void main(List<String> args) {
  final File f = File(args[0]);
  final Uint8List bytes = f.readAsBytesSync();
  final String name = f.uri.pathSegments.last;
  final String stem =
      name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
  final Map<String, Object?> book =
      name.toLowerCase().endsWith('.epub')
          ? parseEpubFile(bytes, stem, (String n, List<int> d) {})
          : parseTxt(bytes, stem);
  stdout.write(jsonEncode(book));
}
