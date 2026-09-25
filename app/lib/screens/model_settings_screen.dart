import 'package:flutter/material.dart';
import 'package:thusfar_core/thusfar_core.dart';
import 'package:thusfar_core/llm.dart' as llm;

import '../data/model_settings.dart';
import '../ui/theme.dart';

/// Makes saved settings effective for the engine (`model_settings.apply_environment`).
void applyModelEnvironment(ModelSettings s) {
  final (String url, String model, _) = s.read();
  environ['SECRETS_FILE'] = s.file.path;
  for (final String name in const <String>[
    'EXTRACT_MODEL',
    'LOCAL_MODEL',
    'RECAP_MODEL',
    'JUDGE_MODEL',
    'CLASSIFY_MODEL',
    'QA_MODEL',
    'MARGINALIA_MODEL',
    'MARGINALIA_AUTO_MODEL',
  ]) {
    environ[name] = model;
  }
  environ['JEV_ROUTE'] = 'free-only';
  environ['LLM_BASE_URL'] = url;
  llm.resetEnvCache();
}

class _Preset {
  const _Preset(this.name, this.url, this.model);

  final String name;
  final String url;
  final String model;
}

const List<_Preset> _presets = <_Preset>[
  _Preset(
    'DeepSeek 官方',
    'https://api.deepseek.com/v1',
    'deepseek-flash+nothink',
  ),
  _Preset('小鲸', 'https://open.xiaojingai.com/v1', 'deepseek-flash+nothink'),
  _Preset('自定义', '', ''),
];

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

  int get _preset {
    for (int i = 0; i < 2; i++) {
      if (_presets[i].url == url.text.trim()) return i;
    }
    return 2;
  }

  Future<void> _test() async {
    setState(() {
      test = _Test.running;
      testMessage = '';
    });
    applyModelEnvironment(widget.settings);
    final String name = widget.settings.read().$2;
    final Stopwatch w = Stopwatch()..start();
    try {
      final llm.ChatResult r = await llm.chat(
        name,
        const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': '只回答两个字：可以'},
        ],
        maxTokens: 16,
        temperature: 0,
        timeout: 30,
        retries: 0,
      );
      final double s = w.elapsedMilliseconds / 1000;
      final String reply = r.text.trim();
      setState(() {
        test = s > 8 ? _Test.slow : _Test.ok;
        testMessage = s > 8
            ? '这个模型回复很慢（${s.toStringAsFixed(1)} 秒），整理一本书会很久；想快一些可以换 deepseek-flash+nothink'
            : '连接成功 · ${s.toStringAsFixed(1)} 秒 · 回复「${reply.length > 20 ? reply.substring(0, 20) : reply}」';
      });
      if (widget.returnOnSuccess && mounted && test == _Test.ok) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop(true);
      }
    } on Object catch (e) {
      setState(() {
        test = _Test.failed;
        testMessage =
            llm.explain(e) ??
            '连接失败：${e.toString().length > 200 ? e.toString().substring(0, 200) : e}';
      });
    }
  }

  void _save() {
    final (String u, String m) = ModelSettings.normalize(url.text, model.text);
    final String? e = widget.settings.save(
      url: url.text,
      model: model.text,
      key: key.text.trim(),
      clearKey: clearKey,
    );
    setState(() {
      error = e;
      urlNote = u != url.text.trim() && u.endsWith('/v1') ? '已自动补上 /v1' : null;
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
    if (e == null) _test();
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
          Row(
            children: <Widget>[
              for (int i = 0; i < _presets.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i < 2 ? 10 : 0),
                    child: GestureDetector(
                      onTap: () => setState(() {
                        if (i < 2) {
                          url.text = _presets[i].url;
                          model.text = _presets[i].model;
                        }
                      }),
                      child: Container(
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: t.raised,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _preset == i ? t.ink : t.rule,
                            width: _preset == i ? 1.6 : 1,
                          ),
                        ),
                        child: Text(
                          _presets[i].name,
                          style: TextStyle(
                            fontSize: 14,
                            color: t.ink,
                            fontWeight: _preset == i
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: deco('接口地址', helper: urlNote),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: model,
            decoration: deco('模型', helper: modelNote),
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
                    onPressed: () => setState(() => replacing = true),
                    child: const Text('更换'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => clearKey = true),
                    child: Text('清除', style: TextStyle(color: t.danger)),
                  ),
                ],
              ),
            )
          else
            TextField(
              controller: key,
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
                child: Pill(label: '保存', filled: true, onTap: _save),
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
