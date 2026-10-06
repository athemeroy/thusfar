import 'dart:convert';
import 'dart:typed_data';

/// Safe display metadata only. Never returns credentials or book text.
class BackupSummary {
  const BackupSummary({
    required this.title,
    required this.bytes,
    this.id,
    this.exported,
    this.customizationSummary,
  });
  final String title;
  final int bytes;
  final String? id;
  final DateTime? exported;
  final String? customizationSummary;

  factory BackupSummary.read(Uint8List bytes, {String fallback = '未命名书籍'}) {
    try {
      final Object? raw = jsonDecode(utf8.decode(bytes));
      if (raw is Map<String, Object?>) {
        final Object? book = raw['book'];
        final Object? meta = raw['meta'];
        final Object? title =
            raw['format'] == 'thusfar-web-backup-v1' && meta is Map
            ? meta['title']
            : book is Map
            ? book['title']
            : null;
        final Object? stamp = raw['exported'];
        final Object? native = raw['native_backup'];
        final Object? custom =
            raw['reader_customizations'] ??
            (native is Map ? native['reader_customizations'] : null);
        String? customizationSummary;
        if (custom is Map) {
          final Object? rules = custom['purification'];
          final int count = rules is List ? rules.length : 0;
          customizationSummary =
              '本书净化规则 $count 条'
              '${custom['directory'] == null ? '' : '；含 TXT 目录设置'}。'
              '现有规则的顺序和启用选择保留，新增规则追加；目录冲突会停止恢复。'
              '单书备份不含全局净化规则，请用整库 ZIP 或单独导出规则。';
        }
        return BackupSummary(
          title: title is String && title.trim().isNotEmpty
              ? title.trim()
              : fallback,
          bytes: bytes.length,
          customizationSummary: customizationSummary,
          id: raw['id'] is String
              ? raw['id'] as String
              : meta is Map && meta['id'] is String
              ? meta['id'] as String
              : null,
          exported:
              stamp is num &&
                  stamp.isFinite &&
                  stamp > 0 &&
                  stamp < 8640000000000
              ? DateTime.fromMillisecondsSinceEpoch(
                  (stamp * 1000).round(),
                ).toLocal()
              : null,
        );
      }
    } on Object {
      /* Full validation reports the actual format error. */
    }
    return BackupSummary(title: fallback, bytes: bytes.length);
  }

  String get sizeLabel => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  String get dateLabel => exported == null
      ? '备份时间未知'
      : '${exported!.year}-${exported!.month.toString().padLeft(2, '0')}-${exported!.day.toString().padLeft(2, '0')} ${exported!.hour.toString().padLeft(2, '0')}:${exported!.minute.toString().padLeft(2, '0')}';
}

class RestoreReportEntry {
  const RestoreReportEntry({
    required this.title,
    required this.status,
    this.detail,
  });
  final String title;

  /// imported, merged, conflict
  final String status;
  final String? detail;
  String get label => switch (status) {
    'imported' => '已导入',
    'merged' => '已核对合并',
    _ => '未导入',
  };
  Map<String, Object?> toJson() => {
    'title': title,
    'status': status,
    'detail': detail,
  };
  factory RestoreReportEntry.fromJson(Map<String, Object?> value) =>
      RestoreReportEntry(
        title: '${value['title']}',
        status: '${value['status']}',
        detail: value['detail'] as String?,
      );
}

class RestoreReport {
  const RestoreReport({
    required this.created,
    required this.entries,
    required this.settingsStatus,
  });
  final DateTime created;
  final List<RestoreReportEntry> entries;
  final String settingsStatus;
  int get failed => entries.where((e) => e.status == 'conflict').length;
  String get summary => '${entries.length - failed} 本已恢复，$failed 本未导入';
  Map<String, Object?> toJson() => {
    'created': created.toIso8601String(),
    'entries': entries.map((e) => e.toJson()).toList(),
    'settingsStatus': settingsStatus,
  };
  factory RestoreReport.fromJson(Map<String, Object?> value) => RestoreReport(
    created: DateTime.parse(value['created'] as String),
    entries: (value['entries'] as List<Object?>)
        .map((e) => RestoreReportEntry.fromJson(e as Map<String, Object?>))
        .toList(),
    settingsStatus: value['settingsStatus'] as String,
  );
}
