/// Keep unexpected implementation details out of reader-facing error surfaces.
/// Raw errors remain with the existing diagnostic owner.
String readerMessage(Object? value, {required String fallback}) {
  final String text = '${value ?? ''}'.trim();
  if (text.isEmpty ||
      RegExp(
        r'Exception|Error:|Traceback|Stack trace|https?://|[/\\](?:tmp|Users|home|data)/|\b(?:JSON|HTTP|TLS|Socket|schema|checksum|SHA256|worker|isolate|PROPFIND|OPTIONS)\b|缓存|指纹|校验|跨域|整理锁|原子写入|偏移量|重试意图|质量重试|端点|编码|原文位置',
        caseSensitive: false,
      ).hasMatch(text) ||
      !RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
    final bool costMentioned = RegExp('计费|收费|费用|余额').hasMatch(text);
    return costMentioned && !RegExp('计费|收费|费用|余额').hasMatch(fallback)
        ? '$fallback 本次可能已产生费用。'
        : fallback;
  }
  return text;
}
