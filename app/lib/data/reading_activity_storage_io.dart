import 'dart:io';

class ReadingActivityStorage {
  ReadingActivityStorage(String rootKey)
    : _file = File('$rootKey/.reading-activity.json');
  final File _file;
  String? read() => _file.existsSync() ? _file.readAsStringSync() : null;
  void write(String value) {
    _file.parent.createSync(recursive: true);
    final File pending = File('${_file.path}.pending');
    pending.writeAsStringSync(value, flush: true);
    pending.renameSync(_file.path);
  }
}
