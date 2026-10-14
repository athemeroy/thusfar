import '../ui/reader_message.dart';
import 'package:flutter/material.dart';
import '../data/restore_report.dart';

class RestoreReportView extends StatelessWidget {
  const RestoreReportView({super.key, required this.report});
  final RestoreReport? report;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('上次恢复报告')),
    body: report == null
        ? const Center(child: Text('还没有书库恢复记录'))
        : ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Text(
                report!.summary,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(report!.created.toLocal().toString().split('.').first),
              const SizedBox(height: 12),
              Text(
                '设置：${readerMessage(report!.settingsStatus, fallback: '部分设置未能恢复，请重新检查设置。')}',
              ),
              const SizedBox(height: 12),
              const Text('已成功的书籍无需重复恢复。未导入的版本仍在原备份中；可处理列出的冲突后重试。'),
              for (final RestoreReportEntry entry in report!.entries)
                Card(
                  child: ListTile(
                    leading: Icon(
                      entry.status == 'conflict'
                          ? Icons.warning_amber_outlined
                          : Icons.check_circle_outline,
                    ),
                    title: Text(entry.title),
                    subtitle: SelectableText(
                      '${entry.label}${entry.detail == null ? '' : '\n${readerMessage(entry.detail, fallback: '两个版本的内容不同，暂未合并。请保留备份后再处理。')}'}',
                    ),
                  ),
                ),
            ],
          ),
  );
}
