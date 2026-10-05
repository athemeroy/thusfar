import '../ui/reader_message.dart';
import '../ui/info_button.dart';
import 'package:flutter/foundation.dart';
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
    url: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-flash',
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
    defaultModel: 'claude-haiku-4-5-20251001',
  ),
  _ProviderPreset(
    name: 'Google Gemini',
    protocol: 'gemini',
    url: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-3.5-flash-lite',
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

enum _Test { none, running, ok, slow, saved, unverified, failed }

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  final ScrollController formScroll = ScrollController();
  late final TextEditingController url;
  late final TextEditingController model;
  final TextEditingController key = TextEditingController();
  final TextEditingController classifierKey = TextEditingController();
  final TextEditingController jevApiKey = TextEditingController();
  late String protocol;
  late bool judgeFallback;
  late String judgeMode;
  bool get customJudge => judgeMode != 'free';
  late final TextEditingController judgeModel;
  final TextEditingController judgeKey = TextEditingController();
  bool clearJudgeKey = false;
  late final TextEditingController judgeUrl;
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
  int _operation = 0;
  bool _leaving = false;
  bool _saving = false;
  Map<String, Object?>? _passedDraft;
  Map<String, Object?>? _passedResult;
  late (String, String) _keyEndpoint;
  final Map<(String, String), (String, bool, bool)> _keyDrafts = {};
  final Map<(String, String), String> _modelDrafts = {};

  bool get _busy => test == _Test.running || _saving;

  (String, String) get _endpoint => (
    protocol,
    ModelSettings.normalize(url.text, model.text, protocol: protocol).$1,
  );

  bool get _separateKeyRequired =>
      widget.settings.hasKey &&
      _endpoint != (widget.settings.protocol, widget.settings.read().$1);

  void _syncKeyEndpoint() {
    final (String, String) endpoint = _endpoint;
    if (endpoint == _keyEndpoint) return;
    _keyDrafts[_keyEndpoint] = (key.text, replacing, clearKey);
    final (String, bool, bool)? draft = _keyDrafts[endpoint];
    key.text = draft?.$1 ?? '';
    replacing = draft?.$2 ?? false;
    clearKey = draft?.$3 ?? false;
    showKey = false;
    _keyEndpoint = endpoint;
  }

  Map<String, Object?> _payload() => <String, Object?>{
    'protocol': protocol,
    'base_url': url.text.trim(),
    'model': model.text.trim(),
    'api_key': key.text.trim(),
    'clear_key': clearKey,
    'jev_route': customJudge
        ? judgeMode
        : judgeFallback
        ? 'free-then-model'
        : 'free-only',
    'judge_url': judgeUrl.text.trim(),
    'judge_model': judgeModel.text.trim(),
    'judge_api_key': judgeKey.text.trim(),
    'clear_judge_api_key': clearJudgeKey,
    'classifier_key': classifierKey.text.trim(),
    'clear_classifier_key': clearClassifierKey,
    'jev_api_key': jevApiKey.text.trim(),
    'clear_jev_api_key': clearJevApiKey,
  };

  bool _active(int operation) =>
      mounted &&
      !_leaving &&
      operation == _operation &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    final (String u, String m, _) = widget.settings.read();
    // Show the same initial choice as the browser on a fresh install. Merely
    // opening this screen never saves a model or starts a provider request.
    final _ProviderPreset? firstRunPreset = widget.settings.file.existsSync()
        ? null
        : _presets.firstWhere(
            (_ProviderPreset item) => item.protocol == 'gemini',
          );
    protocol = firstRunPreset?.protocol ?? widget.settings.protocol;
    judgeFallback = widget.settings.judgeFallbackEnabled;
    judgeMode =
        const {'systemone', 'model'}.contains(widget.settings.judgeRoute)
        ? widget.settings.judgeRoute
        : 'free';
    judgeModel = TextEditingController(text: widget.settings.judgeModel);
    judgeUrl = TextEditingController(text: widget.settings.judgeUrl);
    url = TextEditingController(text: firstRunPreset?.url ?? u);
    model = TextEditingController(text: firstRunPreset?.defaultModel ?? m);
    _keyEndpoint = _endpoint;
  }

  @override
  void dispose() {
    _leaving = true;
    _operation++;
    _passedDraft = null;
    _keyDrafts.clear();
    url.dispose();
    model.dispose();
    key.dispose();
    classifierKey.dispose();
    judgeUrl.dispose();
    judgeModel.dispose();
    judgeKey.dispose();
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
    _operation++;
    _syncKeyEndpoint();
    test = _Test.none;
    error = null;
    urlNote = null;
    modelNote = null;
  });

  void _applyPreset(_ProviderPreset p) {
    if (_busy) return;
    HapticFeedback.selectionClick();
    _modelDrafts[_endpoint] = model.text;
    protocol = p.protocol;
    url.text = p.url;
    model.text =
        _modelDrafts[_endpoint] ??
        (_endpoint == (widget.settings.protocol, widget.settings.read().$1)
            ? widget.settings.read().$2
            : p.defaultModel);
    _edited();
  }

  Future<void> _test({bool saveAfter = false}) async {
    if (_busy || _leaving) return;
    HapticFeedback.lightImpact();
    final int operation = ++_operation;
    final Map<String, Object?> payload = _payload();
    Map<String, Object?> draft;
    try {
      draft = widget.settings.preview(payload);
    } on Object catch (e) {
      _failure(e);
      return;
    }
    if ((draft['api_key']! as String).isEmpty) {
      _failure('请先填写服务密钥');
      return;
    }
    // A successful explicit probe applies only to these exact effective
    // settings. Saving or repeatedly tapping never launches a second probe.
    if (mapEquals(draft, _passedDraft)) {
      if (saveAfter) {
        _saveDraft(draft, verified: true);
      } else {
        _reportSuccess(draft, _passedResult!);
      }
      return;
    }
    final String? savedBefore = widget.settings.file.existsSync()
        ? widget.settings.file.readAsStringSync()
        : null;
    setState(() {
      test = _Test.running;
      testMessage = '正在测试连接…';
      error = null;
    });
    _showResult();
    try {
      final Map<String, Object?> result = await widget.settings.test(
        url: draft['base_url']! as String,
        model: draft['model']! as String,
        key: draft['api_key']! as String,
        clearKey: false,
        protocol: draft['protocol']! as String,
        judgeFallback: draft['jev_route'] == 'free-then-model',
        judgeRoute: draft['jev_route']! as String,
        judgeModel: draft['judge_model']! as String,
        judgeKey: draft['judge_api_key']! as String,
        clearJudgeKey: draft['judge_api_key'] == '',
        judgeUrl: draft['judge_url']! as String,
        classifierKey: draft['classifier_key']! as String,
        clearClassifierKey: draft['classifier_key'] == '',
        jevApiKey: draft['jev_api_key']! as String,
        clearJevApiKey: draft['jev_api_key'] == '',
      );
      if (!_active(operation)) return;
      if (!mapEquals(payload, _payload())) {
        setState(() => test = _Test.none);
        return;
      }
      final String? savedNow = widget.settings.file.existsSync()
          ? widget.settings.file.readAsStringSync()
          : null;
      if (savedNow != savedBefore) {
        _failure('已保存的设置在测试期间发生变化，请重新确认后再试');
        return;
      }
      if (result['ok'] != true) {
        _failure('${result['message']}');
        return;
      }
      _passedDraft = Map<String, Object?>.of(draft);
      _passedResult = result;
      if (saveAfter) {
        _saveDraft(draft, verified: true);
      } else {
        _reportSuccess(draft, result);
      }
    } on Object catch (e) {
      if (_active(operation)) _failure(e);
    }
  }

  void _reportSuccess(Map<String, Object?> draft, Map<String, Object?> result) {
    bool saved = false;
    try {
      saved = mapEquals(draft, widget.settings.preview(<String, Object?>{}));
    } on Object {
      // A fresh install has no saved model yet.
    }
    setState(() {
      test = (result['seconds'] as num? ?? 0) > 8 ? _Test.slow : _Test.ok;
      testMessage =
          '${customJudge ? '整理和检查服务均已连接' : 'AI 服务已连接成功'}。'
          '${saved ? '正在使用此设置' : '当前输入尚未保存'}。';
    });
    _showResult();
  }

  void _failure(Object error) {
    setState(() {
      test = _Test.failed;
      final String raw = llm.explain(error) ?? '$error';
      final String detail = raw.contains('判断回答') || raw.contains('System One')
          ? '检查模型没有给出可用的答案，请检查服务地址和模型名称，或换一个检查模型'
          : raw.contains('HTTP 401')
          ? 'AI 服务密钥无效，请重新填写'
          : RegExp(r'Exception|HTTP \d|概率|Traceback').hasMatch(raw)
          ? '连接测试没有成功，请检查服务地址、模型名称和密钥后再试'
          : readerMessage(raw, fallback: '连接失败，请检查服务地址、模型名称和密钥。');
      testMessage =
          '${detail.length > 240 ? detail.substring(0, 240) : detail}。'
          '未保存，原有设置保持不变';
    });
    _showResult();
  }

  void _saveUnverified() {
    if (_busy || _leaving) return;
    HapticFeedback.lightImpact();
    try {
      _saveDraft(widget.settings.preview(_payload()), verified: false);
    } on Object catch (e) {
      _failure(e);
    }
  }

  void _saveDraft(Map<String, Object?> draft, {required bool verified}) {
    if (_saving || _leaving) return;
    _saving = true;
    try {
      final String u = draft['base_url']! as String;
      final String m = draft['model']! as String;
      final String? e = widget.settings.save(
        url: u,
        model: m,
        key: draft['api_key']! as String,
        clearKey: draft['api_key'] == '',
        protocol: draft['protocol']! as String,
        judgeFallback: draft['jev_route'] == 'free-then-model',
        judgeRoute: draft['jev_route']! as String,
        judgeModel: draft['judge_model']! as String,
        judgeKey: draft['judge_api_key']! as String,
        clearJudgeKey: draft['judge_api_key'] == '',
        judgeUrl: draft['judge_url']! as String,
        classifierKey: draft['classifier_key']! as String,
        clearClassifierKey: draft['classifier_key'] == '',
        jevApiKey: draft['jev_api_key']! as String,
        clearJevApiKey: draft['jev_api_key'] == '',
      );
      if (e != null) {
        _failure(e);
        return;
      }
      setState(() {
        error = null;
        urlNote = u != url.text.trim() && u.endsWith('/v1')
            ? '已补全服务地址'
            : u.endsWith('/v1beta') && u != url.text.trim()
            ? '已补全服务地址'
            : null;
        modelNote = m != model.text.trim() && m.endsWith('+nothink')
            ? '已更新模型名称'
            : null;
        url.text = u;
        model.text = m;
        judgeUrl.text = draft['judge_url']! as String;
        judgeModel.text = draft['judge_model']! as String;
        judgeKey.clear();
        clearJudgeKey = false;
        key.clear();
        classifierKey.clear();
        jevApiKey.clear();
        _keyDrafts.clear();
        _modelDrafts.clear();
        _keyEndpoint = _endpoint;
        replacing = false;
        replacingClassifierKey = false;
        replacingJevApiKey = false;
        clearKey = false;
        clearClassifierKey = false;
        clearJevApiKey = false;
        test = verified ? _Test.saved : _Test.unverified;
        testMessage = verified
            ? customJudge
                  ? '整理和检查服务均已连接，设置已生效。'
                  : '连接成功，设置已保存。'
            : '已保存，还未测试连接。';
      });
      _showResult();
      if (verified &&
          widget.returnOnSuccess &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop(true);
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String saved = widget.settings.read().$3;
    final bool hasKey = saved.isNotEmpty && !clearKey && !_separateKeyRequired;
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
    return PopScope(
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          _leaving = true;
          _operation++;
        }
      },
      child: Scaffold(
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
                    '选择 AI 服务',
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
                              protocol == p.protocol &&
                              url.text.trim() == p.url,
                          onTap: _busy ? null : () => _applyPreset(p),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: protocol,
              decoration: deco('服务类型'),
              items: <DropdownMenuItem<String>>[
                for (final MapEntry<String, String> item
                    in ModelSettings.protocolLabels.entries)
                  DropdownMenuItem<String>(
                    value: item.key,
                    child: Text(item.value),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (String? value) {
                      if (value == null || value == protocol) return;
                      HapticFeedback.selectionClick();
                      setState(() {
                        _modelDrafts[_endpoint] = model.text;
                        protocol = value;
                        url.text = ModelSettings.defaultUrls[value]!;
                        model.text =
                            _modelDrafts[_endpoint] ??
                            (_endpoint ==
                                    (
                                      widget.settings.protocol,
                                      widget.settings.read().$1,
                                    )
                                ? widget.settings.read().$2
                                : '');
                        _edited();
                      });
                    },
            ),
            const SizedBox(height: 20),
            TextField(
              controller: url,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: deco('服务地址', helper: urlNote),
              onChanged: (_) => _edited(),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: model,
              onChanged: (_) => _edited(),
              enabled: !_busy,
              decoration: deco('模型', helper: modelNote ?? '填写接口提供的模型名称'),
            ),
            const SizedBox(height: 14),
            if (_separateKeyRequired) ...<Widget>[
              Text(
                '服务已更换，请填写对应的密钥。',
                style: TextStyle(color: t.amber, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 10),
            ],
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
                        '服务密钥：已保存 ···${saved.length >= 4 ? saved.substring(saved.length - 4) : saved}',
                        style: TextStyle(
                          color: t.ink,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              HapticFeedback.selectionClick();
                              setState(() => replacing = true);
                            },
                      child: const Text('更换'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              setState(() {
                                clearKey = true;
                                _edited();
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
                enabled: !_busy,
                obscureText: !showKey,
                decoration: deco(
                  '服务密钥',
                  suffix: IconButton(
                    tooltip: showKey ? '隐藏密钥' : '显示密钥',
                    icon: Icon(
                      showKey ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      setState(() => showKey = !showKey);
                    },
                  ),
                ),
              ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: judgeMode,
              decoration: deco('用什么检查整理结果'),
              items: const [
                DropdownMenuItem(value: 'free', child: Text('免费服务')),
                DropdownMenuItem(value: 'systemone', child: Text('专用检查模型')),
                DropdownMenuItem(value: 'model', child: Text('通用对话模型')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value == null || value == judgeMode) return;
                      setState(() {
                        judgeMode = value;
                        judgeUrl.clear();
                        judgeModel.clear();
                        judgeKey.clear();
                        clearJudgeKey = true;
                        _edited();
                      });
                    },
            ),
            if (customJudge) ...<Widget>[
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: InfoButton(
                  title: '检查整理结果',
                  message:
                      '检查模型负责确认人物、事件等内容是否符合原文。人物小传和问答仍使用上方模型。你可以自行选择检查模型，并在保存前测试连接。',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: judgeUrl,
                enabled: !_busy,
                onChanged: (_) => _edited(),
                decoration: deco(
                  '检查服务地址',
                  helper: judgeMode == 'systemone'
                      ? '填写服务提供的检查地址；使用同一服务时可留空'
                      : '使用上方服务时可留空',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: judgeModel,
                enabled: !_busy,
                onChanged: (_) => _edited(),
                decoration: deco(
                  '检查用的模型（可选）',
                  helper: judgeMode == 'systemone' ? '留空使用服务默认模型' : '留空使用上方模型',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: judgeKey,
                enabled: !_busy,
                obscureText: true,
                onChanged: (value) {
                  if (value.isNotEmpty) clearJudgeKey = false;
                  _edited();
                },
                decoration: deco(
                  '检查服务密钥（可选）',
                  helper: widget.settings.hasJudgeKey && !clearJudgeKey
                      ? '已保存 ****${widget.settings.judgeKeyLast4}；留空保留'
                      : '留空使用上方 服务密钥',
                  suffix: widget.settings.hasJudgeKey && !clearJudgeKey
                      ? IconButton(
                          tooltip: '清除检查服务密钥',
                          icon: const Icon(Icons.clear),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  judgeKey.clear();
                                  clearJudgeKey = true;
                                  _edited();
                                }),
                        )
                      : null,
                ),
              ),
            ],
            if (!customJudge) ...<Widget>[
              const SizedBox(height: 12),
              Material(
                color: t.raised,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SwitchListTile.adaptive(
                  title: const Text('免费服务不可用时，改用上方模型检查'),
                  subtitle: Text(
                    '可能产生模型费用。每本书先允许检查 ${budget.modelJudgeInitialCalls} 次，达到后会暂停；你可以增加次数。',
                  ),
                  value: judgeFallback,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          judgeFallback = value;
                          _edited();
                        }),
                ),
              ),
            ],
            ExpansionTile(
              title: const Text('其他服务的密钥（可选）'),
              children: <Widget>[
                const SizedBox(height: 18),
                Text(
                  'classifier.dev 密钥（可选）',
                  style: TextStyle(
                    fontSize: 14,
                    color: t.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '仅使用 classifier.dev 付费服务时填写，请使用该服务提供的密钥。',
                  style: TextStyle(fontSize: 12, height: 1.4, color: t.ink2),
                ),
                const SizedBox(height: 10),
                if (widget.settings.hasClassifierKey &&
                    !replacingClassifierKey &&
                    !clearClassifierKey)
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '已保存 ···${widget.settings.classifierKeyLast4}',
                        ),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () =>
                                  setState(() => replacingClassifierKey = true),
                        child: const Text('更换'),
                      ),
                      TextButton(
                        onPressed: _busy
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
                    enabled: !_busy,
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
                          showClassifierKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () => setState(
                          () => showClassifierKey = !showClassifierKey,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                Text(
                  'Jev 密钥（可选）',
                  style: TextStyle(
                    fontSize: 14,
                    color: t.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '仅使用 TypeSafe AI / Jev 时填写。保存后，可在书籍详情中选择用它检查内容。',
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
                        onPressed: _busy
                            ? null
                            : () => setState(() => replacingJevApiKey = true),
                        child: const Text('更换'),
                      ),
                      TextButton(
                        onPressed: _busy
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
                    enabled: !_busy,
                    obscureText: !showJevApiKey,
                    onChanged: (String value) {
                      if (value.isNotEmpty) clearJevApiKey = false;
                      _edited();
                    },
                    decoration: deco(
                      'TypeSafe AI / Jev 服务密钥',
                      suffix: IconButton(
                        tooltip: showJevApiKey ? '隐藏密钥' : '显示密钥',
                        icon: Icon(
                          showJevApiKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => showJevApiKey = !showJevApiKey),
                      ),
                    ),
                  ),
              ],
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Pill(label: '测试连接', onTap: _busy ? null : _test),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Pill(
                        label: '测试并保存',
                        filled: true,
                        onTap: _busy ? null : () => _test(saveAfter: true),
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: _busy ? null : _saveUnverified,
                  child: const Text('跳过测试，直接保存'),
                ),
              ],
            ),
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
      _Test.unverified => (t.amber, Icons.info_outline, '设置已保存（未验证）'),
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
