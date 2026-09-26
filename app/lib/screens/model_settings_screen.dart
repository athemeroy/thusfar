import 'package:flutter/material.dart';
import 'package:thusfar_core/llm.dart' as llm;

import '../data/model_settings.dart';
import '../ui/theme.dart';

/// Makes saved settings effective for the engine (`model_settings.apply_environment`).
void applyModelEnvironment(ModelSettings s) => s.applyEnvironment();

/// S19 模型设置: fill in once and confirm it works right here.
class ModelSettingsScreen extends StatefulWidget {
  const ModelSettingsScreen({
    super.key,
    required this.settings,
    this.returnOnSuccess = false,
  });

  final ModelSettings settings;
  final bool returnOnSuccess;

  @override
  State<ModelSettingsScreen> createState() => _ModelSettingsScreenState();
}

enum _Test { none, running, ok, slow, failed }

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  late final TextEditingController url;
  late final TextEditingController model;
  final TextEditingController key = TextEditingController();
  late String protocol;
  bool showKey = false;
  bool replacing = false;
  bool clearKey = false;
  String? error;
  String? urlNote;
  String? modelNote;
  _Test test = _Test.none;
  String testMessage = '';

  @override
  void initState() {
    super.initState();
    final (String u, String m, _) = widget.settings.read();
    protocol = widget.settings.protocol;
    url = TextEditingController(text: u);
    model = TextEditingController(text: m);
  }

  @override
  void dispose() {
    url.dispose();
    model.dispose();
    key.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
    test = _Test.none;
    error = null;
    urlNote = null;
    modelNote = null;
  });

  Future<void> _test({bool saved = false}) async {
    if (test == _Test.running) return;
    if (clearKey || (key.text.trim().isEmpty && !widget.settings.hasKey)) {
      setState(() {
        test = _Test.failed;
        testMessage = '还没有填写模型 API 密钥，请先填写';
      });
      return;
    }
    final (String savedUrl, String savedModel, String savedKey) = widget
        .settings
        .read();
    final (String probeUrl, String probeModel) = ModelSettings.normalize(
      url.text,
      model.text,
      protocol: protocol,
    );
    final String probeKey = clearKey
        ? ''
        : key.text.trim().isEmpty
        ? savedKey
        : key.text.trim();
    final bool unsaved =
        protocol != widget.settings.protocol ||
        probeUrl != savedUrl ||
        probeModel != savedModel ||
        probeKey != savedKey;
    setState(() {
      test = _Test.running;
      testMessage = '';
    });
    try {
      final Map<String, Object?> result = await widget.settings.test(
        url: url.text,
        model: model.text,
        key: key.text,
        clearKey: clearKey,
        protocol: protocol,
      );
      if (!mounted) return;
      setState(() {
        test = result['ok'] != true
            ? _Test.failed
            : (result['seconds'] as num) > 8
            ? _Test.slow
            : _Test.ok;
        testMessage = '${result['message']}';
        if (unsaved && result['ok'] == true) testMessage += '。当前输入尚未保存';
      });
      if (saved && widget.returnOnSuccess && mounted && test == _Test.ok) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop(true);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        test = _Test.failed;
        testMessage =
            llm.explain(e) ??
            '连接失败：${e.toString().length > 200 ? e.toString().substring(0, 200) : e}';
      });
    }
  }

  void _save() {
    if (test == _Test.running) return;
    final (String u, String m) = ModelSettings.normalize(
      url.text,
      model.text,
      protocol: protocol,
    );
    final String? e = widget.settings.save(
      url: url.text,
      model: model.text,
      key: key.text.trim(),
      clearKey: clearKey,
      protocol: protocol,
    );
    setState(() {
      error = e;
      urlNote = u != url.text.trim() && u.endsWith('/v1')
          ? '已自动补上 /v1'
          : u.endsWith('/v1beta') && u != url.text.trim()
          ? '已自动补上 /v1beta'
          : null;
      modelNote = m != model.text.trim() && m.endsWith('+nothink')
          ? '已自动加上 +nothink'
          : null;
      if (e == null) {
        url.text = u;
        model.text = m;
        key.clear();
        replacing = false;
        clearKey = false;
      }
    });
    if (e == null) {
      applyModelEnvironment(widget.settings);
      _test(saved: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String saved = widget.settings.read().$3;
    final bool hasKey = saved.isNotEmpty && !clearKey;
    InputDecoration deco(String label, {String? helper, Widget? suffix}) =>
        InputDecoration(
          labelText: label,
          helperText: helper,
          helperStyle: TextStyle(color: t.ok),
          suffixIcon: suffix,
          filled: true,
          fillColor: t.raised,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: t.rule),
          ),
        );
    return Scaffold(
      backgroundColor: t.paper,
      appBar: AppBar(
        backgroundColor: t.paper,
        surfaceTintColor: Colors.transparent,
        title: const Text('模型设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: <Widget>[
          DropdownButtonFormField<String>(
            initialValue: protocol,
            decoration: deco('接口协议'),
            items: <DropdownMenuItem<String>>[
              for (final MapEntry<String, String> item
                  in ModelSettings.protocolLabels.entries)
                DropdownMenuItem<String>(
                  value: item.key,
                  child: Text(item.value),
                ),
            ],
            onChanged: test == _Test.running
                ? null
                : (String? value) {
                    if (value == null || value == protocol) return;
                    setState(() {
                      protocol = value;
                      url.text = ModelSettings.defaultUrls[value]!;
                      model.clear();
                      key.clear();
                      replacing = true;
                      clearKey = false;
                      urlNote = null;
                      modelNote = null;
                      test = _Test.none;
                      error = null;
                    });
                  },
          ),
          const SizedBox(height: 20),
          TextField(
            controller: url,
            enabled: test != _Test.running,
            keyboardType: TextInputType.url,
            decoration: deco('接口地址', helper: urlNote),
            onChanged: (_) => _edited(),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: model,
            onChanged: (_) => _edited(),
            enabled: test != _Test.running,
            decoration: deco('模型', helper: modelNote ?? '填写接口提供的模型名称'),
          ),
          const SizedBox(height: 14),
          if (hasKey && !replacing)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              decoration: BoxDecoration(
                color: t.raised,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.rule),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'API 密钥：已保存 ···${saved.length >= 4 ? saved.substring(saved.length - 4) : saved}',
                      style: TextStyle(color: t.ink),
                    ),
                  ),
                  TextButton(
                    onPressed: test == _Test.running
                        ? null
                        : () => setState(() => replacing = true),
                    child: const Text('更换'),
                  ),
                  TextButton(
                    onPressed: test == _Test.running
                        ? null
                        : () => setState(() {
                            clearKey = true;
                            test = _Test.none;
                          }),
                    child: Text('清除', style: TextStyle(color: t.danger)),
                  ),
                ],
              ),
            )
          else
            TextField(
              controller: key,
              onChanged: (String value) {
                if (value.isNotEmpty && clearKey) {
                  clearKey = false;
                  replacing = true;
                }
                _edited();
              },
              enabled: test != _Test.running,
              obscureText: !showKey,
              decoration: deco(
                'API 密钥',
                suffix: IconButton(
                  icon: Icon(showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => showKey = !showKey),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: t.danger)),
            ),
          const SizedBox(height: 20),
          if (test != _Test.none) _testCard(context),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            12 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Pill(
                  label: '测试连接',
                  onTap: test == _Test.running ? null : _test,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Pill(
                  label: '保存',
                  filled: true,
                  onTap: test == _Test.running ? null : _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _testCard(BuildContext context) {
    final Tokens t = context.tk;
    final (Color c, IconData i, String title) = switch (test) {
      _Test.running => (t.ink3, Icons.hourglass_top, '正在测试…'),
      _Test.ok => (t.ok, Icons.check_circle, '连接成功'),
      _Test.slow => (t.amber, Icons.speed, '能用，但很慢'),
      _ => (t.danger, Icons.error_outline, '连接失败'),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(i, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(color: c, fontWeight: FontWeight.w600),
                ),
                if (testMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      testMessage,
                      style: TextStyle(color: t.ink, height: 1.5),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
