// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

class ReadingActivityStorage {
  ReadingActivityStorage(String rootKey)
    : _key = 'thusfar.reading-activity.$rootKey';
  final String _key;
  String? read() => html.window.localStorage[_key];
  void write(String value) => html.window.localStorage[_key] = value;
}
