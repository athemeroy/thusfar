import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';

/// Reports Android's settings, not a promise that an OEM will keep us running.
class BackgroundProcessingScreen extends StatefulWidget {
  const BackgroundProcessingScreen({super.key});

  @override
  State<BackgroundProcessingScreen> createState() =>
      _BackgroundProcessingScreenState();
}

class _BackgroundProcessingScreenState extends State<BackgroundProcessingScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(
    'thusfar/background_settings',
  );
  Map<String, Object?>? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final Map<String, Object?>? status = await _channel
          .invokeMapMethod<String, Object?>('status');
      if (mounted) {
        setState(() {
          _status = status;
          _error = status == null ? '暂时无法读取手机设置，请稍后重试。' : null;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _error = '暂时无法读取手机设置，请稍后重试。');
      }
    }
  }

  Future<void> _open(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
      // Opening a settings page does not mean permission was granted.
      await _refresh();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请长按页读图标，打开应用信息中的耗电管理。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool exempt = _status?['batteryExempt'] == true;
    final bool notifications = _status?['notifications'] == true;
    final String maker = (_status?['manufacturer'] as String? ?? '')
        .toLowerCase();
    final bool oppo = <String>['oppo', 'oneplus', 'realme'].contains(maker);
    return Scaffold(
      backgroundColor: context.tk.paper,
      appBar: AppBar(title: const Text('切到后台继续整理')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          const Text('切换应用或锁屏后，手机可能限制页读运行。请允许页读在后台继续整理。'),
          const SizedBox(height: 16),
          if (_error != null) ...<Widget>[
            Text(_error!),
            TextButton(onPressed: _refresh, child: const Text('重新读取')),
          ] else if (_status == null)
            const LinearProgressIndicator(),
          if (_status?['powerSave'] == true)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('手机正在省电模式下运行。长时间整理时，请先关闭省电模式。'),
            ),
          const Text(
            '1. 允许后台运行',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(exempt ? '已允许页读不受系统电池优化限制。' : '点击下面的按钮，在手机弹窗中选择允许。持续整理会增加耗电。'),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _status == null || exempt
                  ? null
                  : () => _open('requestBatteryExemption'),
              child: Text(exempt ? '已允许' : '允许后台运行'),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            oppo ? '2. 检查 OPPO 等手机的耗电管理' : '2. 检查手机的耗电管理',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            oppo
                ? '打开下方设置，找到“耗电管理”或“电池使用”，选择“允许后台活动”或“不限制”。不同系统的名称可能不同。'
                : '打开下方设置，在电池或耗电管理中允许后台活动。不同手机的选项名称可能不同。',
          ),
          const SizedBox(height: 8),
          Text(
            _status?['backgroundRestricted'] == true
                ? '手机当前仍在限制页读的后台活动。'
                : '这一项需要你在手机设置里确认，页读无法读取所有厂商的开关。',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => _open('openAppSettings'),
              child: const Text('打开页读的手机设置'),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '3. 显示整理进度',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(notifications ? '页读通知已开启。整理时可在通知栏查看进度。' : '开启页读通知，在通知栏查看整理进度。'),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => _open('openNotificationSettings'),
              child: const Text('打开通知设置'),
            ),
          ),
          const SizedBox(height: 20),
          const Text('设置后，回到书籍页面继续整理，再切换应用或锁屏。回来后查看已整理的段数是否增加。'),
        ],
      ),
    );
  }
}
