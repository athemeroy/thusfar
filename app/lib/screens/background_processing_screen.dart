import '../ui/info_button.dart';
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
    return Scaffold(
      backgroundColor: context.tk.paper,
      appBar: AppBar(title: const Text('切到后台继续整理')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          const Text('切换应用或锁屏后，继续整理书籍。'),
          const SizedBox(height: 16),
          if (_error != null) ...<Widget>[
            Text(_error!),
            TextButton(onPressed: _refresh, child: const Text('重新读取')),
          ] else if (_status == null)
            const LinearProgressIndicator(),
          if (_status?['powerSave'] == true)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('手机正在省电模式下运行，请先关闭省电模式。'),
            ),
          const Text(
            '1. 允许后台运行',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(exempt ? '手机已允许页读持续运行。' : '请在手机弹窗中选择允许。持续整理会增加耗电。'),
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
            '2. 允许后台活动',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text('在手机的耗电管理中，选择“允许后台活动”或“不限制”。'),
          const SizedBox(height: 8),
          if (_status?['backgroundRestricted'] == true)
            const Text('手机仍在限制页读的后台活动。'),
          const Align(
            alignment: Alignment.centerLeft,
            child: InfoButton(
              title: '后台活动设置',
              message:
                  '不同手机的选项名称可能不同。第一步显示已允许后，也请检查这一项。如果找不到入口，可长按页读图标，打开应用信息中的耗电管理。',
            ),
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
          Text(notifications ? '通知已开启，可在通知栏查看进度。' : '开启页读通知，在通知栏查看整理进度。'),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => _open('openNotificationSettings'),
              child: const Text('打开通知设置'),
            ),
          ),
          const SizedBox(height: 20),
          const Text('设置完成后，回到书籍页面继续整理。'),
        ],
      ),
    );
  }
}
