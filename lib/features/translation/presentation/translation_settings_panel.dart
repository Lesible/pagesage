import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/app_select_field.dart';
import '../../../domain/ai/ai_models.dart';
import '../../../domain/translation/translation_models.dart';
import '../../settings/application/ai_settings_providers.dart';
import '../../settings/presentation/model_picker_button.dart';
import '../application/translation_providers.dart';
import '../application/translation_settings_controller.dart';

final class TranslationSettingsPanel extends ConsumerStatefulWidget {
  const TranslationSettingsPanel({super.key});

  @override
  ConsumerState<TranslationSettingsPanel> createState() =>
      _TranslationSettingsPanelState();
}

final class _TranslationSettingsPanelState
    extends ConsumerState<TranslationSettingsPanel> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _appId = TextEditingController();
  final _secret = TextEditingController();
  final _interval = TextEditingController(text: '1');
  final _sample = TextEditingController(
    text: 'Reading makes it possible to explore new ideas.',
  );
  TranslationProfile? _saved;
  String _id = const Uuid().v4();
  TranslationProvider _provider = TranslationProvider.qwen;
  TranslationProtocol _protocol = TranslationProtocol.openAi;
  String _source = 'auto';
  String _target = 'zh';
  String? _aiId;
  bool _initialized = false;
  bool _busy = false;
  bool _clearSecret = false;
  bool _showSecret = false;
  bool _error = false;
  String? _feedback;
  String? _result;
  List<String> _models = const [];
  AiCancelToken? _token;
  int _generation = 0;

  TranslationSettingsController get _controller =>
      ref.read(translationSettingsControllerProvider);

  void _load(TranslationProfile? profile) {
    _generation++;
    _token?.cancel();
    _saved = profile;
    _id = profile?.id ?? const Uuid().v4();
    _provider = profile?.provider ?? TranslationProvider.qwen;
    _protocol = profile?.protocol ?? TranslationProtocol.openAi;
    _name.text = profile?.name ?? '新翻译配置';
    _endpoint.text = profile?.endpoint ?? _provider.defaultEndpoint;
    _model.text = profile?.model ?? _provider.defaultModel;
    _appId.text = profile?.appId ?? '';
    _source = profile?.sourceLanguage ?? 'auto';
    _target = profile?.targetLanguage ?? 'zh';
    _aiId = profile?.aiProfileId;
    _interval.text =
        ((profile?.requestIntervalMs ??
                    TranslationProfile.defaultRequestIntervalMs) /
                1000)
            .toString()
            .replaceFirst(RegExp(r'\.0$'), '');
    _secret.clear();
    _clearSecret = false;
    _busy = false;
    _feedback = null;
    _result = null;
    _models = const [];
  }

  TranslationProfile _draft() => TranslationProfile(
    id: _id,
    name: _name.text.trim(),
    provider: _provider,
    endpoint: _endpoint.text.trim(),
    model: _model.text.trim(),
    appId: _appId.text.trim(),
    protocol: _protocol,
    sourceLanguage: _source,
    targetLanguage: _target,
    aiProfileId: _aiId,
    revision: _saved?.revision ?? 0,
    credentialRef: _saved?.credentialRef,
    requestIntervalMs:
        _intervalMs ?? TranslationProfile.defaultRequestIntervalMs,
  );

  int? get _intervalMs {
    final seconds = double.tryParse(_interval.text.trim());
    if (seconds == null || !seconds.isFinite || seconds < 0 || seconds > 60) {
      return null;
    }
    return (seconds * 1000).round();
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _run(Future<String> Function(int generation) action) async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _feedback = null;
      _error = false;
      _token = null;
      _result = null;
    });
    try {
      final message = await action(generation);
      if (_current(generation)) setState(() => _feedback = message);
    } on Object catch (error) {
      if (_current(generation)) {
        setState(() {
          _error = error is! AiChatCancelledException;
          _feedback = switch (error) {
            TranslationException() => error.message,
            AiChatException() => error.message,
            _ => '操作失败，请检查配置、系统安全存储或网络后重试；输入已保留',
          };
        });
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool translate = false}) async {
    if (!_formKey.currentState!.validate()) return;
    if (_provider == TranslationProvider.ai && _aiId == null) {
      setState(() {
        _error = true;
        _feedback = '请选择 AI 配置，或先到 AI 菜单新增配置';
      });
      return;
    }
    await _run((generation) async {
      final saved = await _controller.save(
        _draft(),
        secret: _secret.text,
        clearSecret: _clearSecret,
      );
      if (!_current(generation)) return '';
      setState(() {
        _saved = saved;
        _secret.clear();
        _clearSecret = false;
      });
      if (!translate) return '翻译配置已保存';
      final token = AiCancelToken();
      setState(() => _token = token);
      final result = await _controller.translate(saved.id, _sample.text, token);
      if (_current(generation)) setState(() => _result = result.text);
      return '配置已保存，试译完成';
    });
  }

  Future<void> _fetchModels() => _run((generation) async {
    final token = AiCancelToken();
    setState(() => _token = token);
    final models = await _controller.fetchModels(
      _draft(),
      _secret.text.trim(),
      token,
      useSavedSecret: !_clearSecret,
    );
    if (_current(generation)) setState(() => _models = models);
    return '已拉取 ${models.length} 个模型，可选择或手动输入';
  });

  Future<void> _delete() async {
    final profile = _saved;
    if (profile == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除翻译配置？'),
        content: const Text('将移除这组配置和对应凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run((generation) async {
      await _controller.delete(profile);
      if (_current(generation)) setState(() => _load(null));
      return '已删除翻译配置';
    });
  }

  @override
  void dispose() {
    _generation++;
    _token?.cancel();
    for (final controller in [
      _name,
      _endpoint,
      _model,
      _appId,
      _secret,
      _interval,
      _sample,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(translationSettingsProvider);
    final aiProfiles = ref.watch(aiProfilesProvider);
    return settings.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, stack) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('无法读取翻译配置，请检查安全存储或应用版本'),
          TextButton.icon(
            onPressed: () => ref.invalidate(translationSettingsProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('重新读取'),
          ),
        ],
      ),
      data: (settings) {
        if (!_initialized) {
          _load(
            settings.profiles
                .where((profile) => profile.id == settings.defaultProfileId)
                .firstOrNull,
          );
          _initialized = true;
        }
        final draft = _draft();
        final profiles = aiProfiles.asData?.value ?? const <AiProfile>[];
        final referencedAiExists = profiles.any(
          (profile) => profile.id == _aiId,
        );
        return Material(
          color: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x5),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('翻译配置组', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('翻译服务单独管理；选择 AI 时引用 AI 菜单中的配置。'),
                  if (settings.hasPendingCredentialCleanup) ...[
                    const SizedBox(height: 8),
                    const Text('部分旧凭据尚未清理；请解锁系统凭据服务后重新读取配置。'),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => ref.invalidate(translationSettingsProvider),
                        child: const Text('重试清理旧凭据'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  AppSelectField<String>(
                    key: ValueKey(
                      'translation-profile-${_saved?.id}-${settings.profiles.length}',
                    ),
                    value:
                        settings.profiles.any(
                          (profile) => profile.id == _saved?.id,
                        )
                        ? _saved?.id
                        : null,
                    label: '已有配置',
                    hint: '新增或选择配置',
                    options: [
                      for (final profile in settings.profiles)
                        AppSelectOption(
                          value: profile.id,
                          label:
                              '${profile.name}${profile.id == settings.defaultProfileId ? '（默认）' : ''}',
                          description: profile.provider.label,
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) => setState(
                            () => _load(
                              settings.profiles
                                  .where((profile) => profile.id == id)
                                  .firstOrNull,
                            ),
                          ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _load(null)),
                      icon: const Icon(Icons.add),
                      label: const Text('新增翻译配置'),
                    ),
                  ),
                  _field('translation-name', '配置名称', _name),
                  const SizedBox(height: 16),
                  AppSelectField<TranslationProvider>(
                    key: ValueKey('translation-provider-$_id-$_provider'),
                    value: _provider,
                    label: '供应商',
                    options: [
                      for (final provider in TranslationProvider.values)
                        AppSelectOption(value: provider, label: provider.label),
                    ],
                    onChanged: _busy
                        ? null
                        : (provider) {
                            setState(() {
                              _provider = provider;
                              _endpoint.text = provider.defaultEndpoint;
                              _model.text = provider.defaultModel;
                              _appId.clear();
                              _secret.clear();
                              _clearSecret = false;
                              _models = const [];
                              _result = null;
                            });
                          },
                  ),
                  const SizedBox(height: 16),
                  if (_provider == TranslationProvider.ai) ...[
                    if (aiProfiles.isLoading) const LinearProgressIndicator(),
                    if (aiProfiles.hasError)
                      TextButton(
                        onPressed: () => ref.invalidate(aiProfilesProvider),
                        child: const Text('AI 配置读取失败，重试'),
                      ),
                    AppSelectField<String>(
                      key: ValueKey('translation-ai-$_aiId-${profiles.length}'),
                      value: referencedAiExists ? _aiId : null,
                      label: 'AI 配置',
                      helperText: _aiId != null && !referencedAiExists
                          ? '原配置已不可用，请重新选择'
                          : '接口、模型和密钥在 AI 菜单维护；翻译独立于聊天开关。',
                      options: [
                        for (final profile in profiles)
                          AppSelectOption(
                            value: profile.id,
                            label: '${profile.name} · ${profile.model}',
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (id) => setState(() => _aiId = id),
                    ),
                  ] else ...[
                    if (_provider == TranslationProvider.custom) ...[
                      AppSelectField<TranslationProtocol>(
                        key: ValueKey('translation-protocol-$_id-$_protocol'),
                        value: _protocol,
                        label: '接口协议',
                        options: [
                          for (final protocol in TranslationProtocol.values)
                            AppSelectOption(
                              value: protocol,
                              label: protocol.label,
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (protocol) {
                                setState(() {
                                  _protocol = protocol;
                                  _models = const [];
                                  _secret.clear();
                                  _clearSecret = false;
                                });
                              },
                      ),
                      const SizedBox(height: 16),
                    ],
                    _field(
                      'translation-endpoint',
                      draft.usesModel ? 'Base URL' : '翻译接口地址',
                      _endpoint,
                      helper: _provider == TranslationProvider.deepl
                          ? 'API Free 使用 https://api-free.deepl.com/v2/translate；其他套餐按控制台填写。'
                          : draft.usesModel
                          ? '填写 API 根地址，如 https://example.com/v1'
                          : '填写完整文本翻译接口地址',
                    ),
                    const SizedBox(height: 16),
                    if (draft.usesAppId) ...[
                      _field(
                        'translation-app-id',
                        _provider == TranslationProvider.baidu
                            ? 'APP ID'
                            : '应用 ID（appKey）',
                        _appId,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (draft.usesModel) ...[
                      _field('translation-model', '模型', _model),
                      if (_provider == TranslationProvider.custom)
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: _busy ? null : _fetchModels,
                              icon: const Icon(Icons.cloud_download_outlined),
                              label: const Text('拉取模型'),
                            ),
                            if (_models.isNotEmpty)
                              ModelPickerButton(
                                models: _models,
                                onSelected: _busy
                                    ? null
                                    : (model) =>
                                          setState(() => _model.text = model),
                              ),
                          ],
                        ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      key: const ValueKey('translation-secret'),
                      controller: _secret,
                      enabled: !_busy && !_clearSecret,
                      obscureText: !_showSecret,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: draft.usesAppId ? '应用密钥' : 'API Key',
                        helperText: _saved?.hasCredential == true
                            ? '已有凭据；留空保留。更换地址或应用后需重新输入。'
                            : draft.credentialOptional
                            ? '自托管服务无需鉴权时可留空。'
                            : '仅保存在系统安全存储，不进入数据库和备份。',
                        helperMaxLines: 3,
                        errorMaxLines: 3,
                        suffixIcon: IconButton(
                          tooltip: _showSecret ? '隐藏凭据' : '显示凭据',
                          onPressed: () =>
                              setState(() => _showSecret = !_showSecret),
                          icon: Icon(
                            _showSecret
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                    ),
                    if (_saved?.hasCredential == true)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('清除已保存凭据'),
                        value: _clearSecret,
                        onChanged: _busy
                            ? null
                            : (value) =>
                                  setState(() => _clearSecret = value ?? false),
                      ),
                  ],
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      Widget language(bool source) => AppSelectField<String>(
                        key: ValueKey(
                          'translation-${source ? 'source' : 'target'}-${source ? _source : _target}',
                        ),
                        value: source ? _source : _target,
                        label: source ? '源语言' : '目标语言',
                        options: [
                          for (final language in translationLanguages.entries)
                            if (source || language.key != 'auto')
                              AppSelectOption(
                                value: language.key,
                                label: language.value,
                              ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) {
                                setState(() {
                                  if (source) {
                                    _source = value;
                                  } else {
                                    _target = value;
                                  }
                                });
                              },
                      );
                      return constraints.maxWidth >= 420
                          ? Row(
                              children: [
                                Expanded(child: language(true)),
                                const SizedBox(width: 16),
                                Expanded(child: language(false)),
                              ],
                            )
                          : Column(
                              children: [
                                language(true),
                                const SizedBox(height: 16),
                                language(false),
                              ],
                            );
                    },
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const ValueKey('translation-request-interval'),
                    controller: _interval,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '请求间隔',
                      suffixText: '秒',
                      helperText: '请求结束后等待；默认 1 秒，0 表示不等待。',
                      helperMaxLines: 4,
                    ),
                    validator: (_) =>
                        _intervalMs == null ? '请输入 0～60 秒之间的有效数字' : null,
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : () => _save(),
                        child: const Text('保存翻译配置'),
                      ),
                      if (_saved != null &&
                          settings.defaultProfileId != _saved?.id)
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run((_) async {
                                  await _controller.setDefault(_saved!.id);
                                  return '已设为默认翻译配置';
                                }),
                          child: const Text('设为默认'),
                        ),
                      if (_saved != null)
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _load(
                                    settings.profiles
                                        .where(
                                          (profile) => profile.id == _saved?.id,
                                        )
                                        .firstOrNull,
                                  ),
                                ),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('重新读取'),
                        ),
                      if (_saved != null)
                        TextButton(
                          onPressed: _busy ? null : _delete,
                          child: const Text('删除配置'),
                        ),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                    if (_token != null)
                      TextButton(
                        onPressed: () {
                          _token?.cancel();
                        },
                        child: const Text('取消网络请求'),
                      ),
                  ],
                  if (_feedback != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _feedback!,
                          style: TextStyle(
                            color: _error
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),
                      ),
                    ),
                  const Divider(height: 40),
                  Text('试译', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('保存当前配置后发送下方文本，可能消耗服务额度。试译不写入书籍。'),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('translation-sample'),
                    controller: _sample,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 6,
                    maxLength: 6000,
                    decoration: const InputDecoration(labelText: '试译文本'),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _save(translate: true),
                      icon: const Icon(Icons.translate),
                      label: const Text('保存并试译'),
                    ),
                  ),
                  if (_result != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(_result!),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    String? helper,
  }) => TextFormField(
    key: ValueKey(key),
    controller: controller,
    enabled: !_busy,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    validator: (value) => value?.trim().isEmpty != false ? '请填写$label' : null,
    onChanged: (_) {
      if (key == 'translation-endpoint') setState(() => _models = const []);
    },
  );
}
