class ReadingActivityStorage {
  ReadingActivityStorage(String rootKey);
  String? _value;
  String? read() => _value;
  void write(String value) => _value = value;
}
