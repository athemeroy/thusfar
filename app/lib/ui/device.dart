import 'dart:io';

/// Phones can receive a book through the system share sheet ("用页读打开").
bool get isPhone => Platform.isAndroid || Platform.isIOS;

/// What the reader calls the device the library lives on, for copy such as
/// "书和笔记保存在这台手机".
String get deviceWord => isPhone ? '手机' : '电脑';
