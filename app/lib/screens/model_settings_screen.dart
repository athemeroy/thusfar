import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/llm.dart' as llm;

import '../data/model_settings.dart';
import '../ui/theme.dart';
import 'package:thusfar_core/judge_budget.dart' as budget;

/// Makes saved settings effective for the engine (`model_settings.apply_environment`).
void applyModelEnvironment(ModelSettings s) => s.applyEnvironment();

class _ProviderPreset {
  const _ProviderPreset({
    required this.name,
    required this.protocol,
    required this.url,
    required this.defaultModel,
  });
  final String name;
  final String protocol;
  final String url;
  final String defaultModel;
}

const List<_ProviderPreset> _presets = <_ProviderPreset>[
  _ProviderPreset(
    name: 'DeepSeek',
    protocol: 'openai',
    url: 'https://api.deepseek.com',
    defaultModel: 'deepseek-chat',
  ),
  _ProviderPreset(
    name: 'SiliconFlow 硅基',
    protocol: 'openai',
    url: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V3',
  ),
  _ProviderPreset(
    name: 'OpenAI',
    protocol: 'openai',
    url: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
  ),
  _ProviderPreset(
    name: 'Claude',
    protocol: 'anthropic',
    url: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-3-5-sonnet-latest',
  ),
  _ProviderPreset(
    name: 'Google Gemini',
    protocol: 'gemini',
    url: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-1.5-flash',
  ),
  _ProviderPreset(
    name: 'Ollama 本地',
    protocol: 'openai',
    url: 'http://localhost:11434/v1',
    defaultModel: 'qwen2.5:7b',
  ),
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

enum _Test { none, running, ok, slow, saved, failed }

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  final ScrollController formScroll = ScrollController();
  late final TextEditingController url;
  late final TextEditingController model;
  final TextEditingController key = TextEditingController();
  final TextEditingController classifierKey = TextEditingController();
  final TextEditingController jevApiKey = TextEditingController();
  late String protocol;
  late bool judgeFallback;
  bool showKey = false;
  bool showClassifierKey = false;
  bool showJevApiKey = false;
  bool replacing = false;
  bool replacingClassifierKey = false;
  bool replacingJevApiKey = false;
  bool clearKey = false;
  bool clearClassifierKey = false;
  bool clearJevApiKey = false;
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
    judgeFallback = widget.settings.judgeFallbackEnabled;
    url = TextEditingController(text: u);
    model = TextEditingController(text: m);
  }

  @override
  void dispose() {
    url.dispose();
    model.dispose();
    key.dispose();
    classifierKey.dispose();
    jevApiKey.dispose();
    formScroll.dispose();
    super.dispose();
  }

  void _showResult() {
    if (formScroll.hasClients) {
      formScroll.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _edited() => setState(() {
    test = _Test.none;
    error = null;
    urlNote = null;
    modelNote = null;
  });

  void _applyPreset(_ProviderPreset p) {
    HapticFeedback.selectionClick();
    setState(() {
      protocol = p.protocol;
      url.text = p.url;
      model.text = p.defaultModel;
      _edited();
    });
  }

  Future<void> _test({bool saved = false}) async {
    if (test == _Test.running) return;
    HapticFeedback.lightImpact();
    if (clearKey || (key.text.trim().isEmpty && !widget.settings.hasKey)) {
      setState(() {
        test = _Test.failed;
        testMessage = '还没有填写模型 API 密钥，请先填写';
      });
      _showResult();
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
        probeKey != savedKey ||
        judgeFallback != widget.settings.judgeFallbackEnabled ||
        classifierKey.text.trim().isNotEmpty ||
        clearClassifierKey ||
        jevApiKey.text.trim().isNotEmpty ||
        clearJevApiKey;
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
        judgeFallback: judgeFallback,
        classifierKey: classifierKey.text,
        clearClassifierKey: clearClassifierKey,
        jevApiKey: jevApiKey.text,
        clearJevApiKey: clearJevApiKey,
      );
      if (!mounted) return;
      setState(() {
        test = result['ok'] != true
            ? _Test.failed
            : (result['seconds'] as num) > 8
            ? _Test.slow
            : _Test.ok;
        testMessage = result['ok'] == true
            ? '模型${result['message']}（此测试未验证 classifier.dev 或 Jev 网关密钥）'
            : '${result['message']}';
        if (unsaved && result['ok'] == true) testMessage += '。当前输入尚未保存';
      });
      _showResult();
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
      _showResult();
    }
  }

  void _save() {
    if (test == _Test.running) return;
    HapticFeedback.lightImpact();
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
      judgeFallback: judgeFallback,
      classifierKey: classifierKey.text,
      clearClassifierKey: clearClassifierKey,
      jevApiKey: jevApiKey.text,
      clearJevApiKey: clearJevApiKey,
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
        classifierKey.clear();
        jevApiKey.clear();
        replacing = false;
        replacingClassifierKey = false;
        replacingJevApiKey = false;
        clearKey = false;
        clearClassifierKey = false;
        clearJevApiKey = false;
      }
    });
    if (e == null) {
      applyModelEnvironment(widget.settings);
      if (widget.settings.hasKey && widget.settings.read().$2.isNotEmpty) {
        _test(saved: true);
      } else {
        setState(() {
          test = _Test.saved;
          testMessage = '密钥已保存。连接测试仅检查上方模型接口，Jev 网关密钥会在你为书籍选择该路线时使用。';
        });
        _showResult();
      }
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
        controller: formScroll,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: <Widget>[
          if (test != _Test.none) ...<Widget>[
            _testCard(context),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '服务商快捷预设',
                  style: TextStyle(
                    fontSize: 13,
                    color: t.ink2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final _ProviderPreset p in _presets)
                      Pill(
                        label: p.name,
                        dense: true,
                        filled:
                            protocol == p.protocol && url.text.trim() == p.url,
                        onTap: test == _Test.running
                            ? null
                            : () => _applyPreset(p),
                      ),
                  ],
                ),
              ],
            ),
          ),
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
                    HapticFeedback.selectionClick();
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
                      style: TextStyle(
                        color: t.ink,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: test == _Test.running
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            setState(() => replacing = true);
                          },
                    child: const Text('更换'),
                  ),
                  TextButton(
                    onPressed: test == _Test.running
                        ? null
                        : () {
                            HapticFeedback.mediumImpact();
                            setState(() {
                              clearKey = true;
                              test = _Test.none;
                            });
                          },
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
                  tooltip: showKey ? '隐藏密钥' : '显示密钥',
                  icon: Icon(showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() => showKey = !showKey);
                  },
                ),
              ),
            ),
          const SizedBox(height: 20),
          Material(
            color: t.raised,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: t.rule),
            ),
            child: SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              title: const Text('免费判断不可用时，使用已配置模型继续'),
              subtitle: Text(
                '此设置作用于所有书籍，会消耗上方模型的 API 额度。每本书初始最多 ${budget.modelJudgeInitialCalls} 次判断、${budget.modelJudgeInitialChars ~/ 10000} 万字符；用完可在书籍详情追加。',
                style: TextStyle(fontSize: 12, color: t.ink2),
              ),
              value: judgeFallback,
              onChanged: test == _Test.running
                  ? null
                  : (bool value) {
                      HapticFeedback.selectionClick();
                      setState(() {
                        judgeFallback = value;
                        _edited();
                      });
                    },
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'classifier.dev 已充值工作区密钥（可选）',
            style: TextStyle(
              fontSize: 14,
              color: t.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '匿名额度用完时，需有余额的 classifier.dev 工作区密钥。会使用该工作区额度；它与上方模型密钥、Jev 网关密钥不同。',
            style: TextStyle(fontSize: 12, height: 1.4, color: t.ink2),
          ),
          const SizedBox(height: 10),
          if (widget.settings.hasClassifierKey &&
              !replacingClassifierKey &&
              !clearClassifierKey)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('已保存 ···${widget.settings.classifierKeyLast4}'),
                ),
                TextButton(
                  onPressed: test == _Test.running
                      ? null
                      : () => setState(() => replacingClassifierKey = true),
                  child: const Text('更换'),
                ),
                TextButton(
                  onPressed: test == _Test.running
                      ? null
                      : () => setState(() {
                          clearClassifierKey = true;
                          _edited();
                        }),
                  child: Text('清除', style: TextStyle(color: t.danger)),
                ),
              ],
            )
          else
            TextField(
              controller: classifierKey,
              enabled: test != _Test.running,
              obscureText: !showClassifierKey,
              onChanged: (String value) {
                if (value.isNotEmpty) clearClassifierKey = false;
                _edited();
              },
              decoration: deco(
                'classifier.dev 密钥',
                suffix: IconButton(
                  tooltip: showClassifierKey ? '隐藏密钥' : '显示密钥',
                  icon: Icon(
                    showClassifierKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => showClassifierKey = !showClassifierKey),
                ),
              ),
            ),
          const SizedBox(height: 18),
          Text(
            'Jev 网关密钥（可选）',
            style: TextStyle(
              fontSize: 14,
              color: t.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '用于 Vercel AI Gateway 的 Jev 接口。保存密钥不会自动启用付费判断；你需要在书籍详情中单独选择。它与 classifier.dev 工作区密钥、上方模型密钥不同。',
            style: TextStyle(fontSize: 12, height: 1.4, color: t.ink2),
          ),
          const SizedBox(height: 10),
          if (widget.settings.hasJevApiKey &&
              !replacingJevApiKey &&
              !clearJevApiKey)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('已保存 ···${widget.settings.jevApiKeyLast4}'),
                ),
                TextButton(
                  onPressed: test == _Test.running
                      ? null
                      : () => setState(() => replacingJevApiKey = true),
                  child: const Text('更换'),
                ),
                TextButton(
                  onPressed: test == _Test.running
                      ? null
                      : () => setState(() {
                          clearJevApiKey = true;
                          _edited();
                        }),
                  child: Text('清除', style: TextStyle(color: t.danger)),
                ),
              ],
            )
          else
            TextField(
              controller: jevApiKey,
              enabled: test != _Test.running,
              obscureText: !showJevApiKey,
              onChanged: (String value) {
                if (value.isNotEmpty) clearJevApiKey = false;
                _edited();
              },
              decoration: deco(
                'Vercel AI Gateway API 密钥',
                suffix: IconButton(
                  tooltip: showJevApiKey ? '隐藏密钥' : '显示密钥',
                  icon: Icon(
                    showJevApiKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => showJevApiKey = !showJevApiKey),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: t.danger)),
            ),
          const SizedBox(height: 20),
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
      _Test.running => (t.qing, Icons.hourglass_top, '正在测试…'),
      _Test.ok => (t.ok, Icons.check_circle, '连接成功'),
      _Test.slow => (t.amber, Icons.speed, '能用，但很慢'),
      _Test.saved => (t.ok, Icons.check_circle, '设置已保存'),
      _ => (t.danger, Icons.error_outline, '连接失败'),
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (test == _Test.running)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: c),
              ),
            )
          else
            Icon(i, color: c, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: c,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                if (testMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      testMessage,
                      style: TextStyle(
                        color: t.ink,
                        height: 1.5,
                        fontSize: 13.5,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
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
