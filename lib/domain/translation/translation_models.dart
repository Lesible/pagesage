import '../ai/ai_models.dart';

enum TranslationProvider {
  baidu('百度翻译', 'https://fanyi-api.baidu.com/api/trans/vip/translate'),
  deepl('DeepL', 'https://api.deepl.com/v2/translate'),
  youdao('有道智云', 'https://openapi.youdao.com/api'),
  tencent('腾讯 TokenHub', 'https://tokenhub.tencentmaas.com/v1'),
  qwen('Qwen-MT', 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
  custom('自定义供应商', ''),
  ai('使用 AI 配置', '');

  const TranslationProvider(this.label, this.defaultEndpoint);

  final String label;
  final String defaultEndpoint;

  String get defaultModel => switch (this) {
    tencent => 'hy-mt3-plus',
    qwen => 'qwen-mt-flash',
    _ => '',
  };
}

enum TranslationProtocol {
  openAi('OpenAI 兼容'),
  libreTranslate('LibreTranslate');

  const TranslationProtocol(this.label);

  final String label;
}

const translationLanguages = {
  'auto': '自动识别',
  'zh': '简体中文',
  'zh-TW': '繁体中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'de': '德语',
  'fr': '法语',
  'es': '西班牙语',
  'ru': '俄语',
  'it': '意大利语',
  'pt': '葡萄牙语',
  'ar': '阿拉伯语',
};

final class TranslationProfile {
  static const defaultRequestIntervalMs = 1000;
  static const maxRequestIntervalMs = 60000;

  const TranslationProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.endpoint,
    this.model = '',
    this.appId = '',
    this.sourceLanguage = 'auto',
    this.targetLanguage = 'zh',
    this.protocol = TranslationProtocol.openAi,
    this.aiProfileId,
    this.credentialRef,
    this.revision = 0,
    this.hasCredential = false,
    this.requestIntervalMs = defaultRequestIntervalMs,
  });

  final String id;
  final String name;
  final TranslationProvider provider;
  final String endpoint;
  final String model;
  final String appId;
  final String sourceLanguage;
  final String targetLanguage;
  final TranslationProtocol protocol;
  final String? aiProfileId;
  final String? credentialRef;
  final int revision;
  final bool hasCredential;
  final int requestIntervalMs;

  bool get usesModel =>
      provider == TranslationProvider.tencent ||
      provider == TranslationProvider.qwen ||
      (provider == TranslationProvider.custom &&
          protocol == TranslationProtocol.openAi);

  bool get usesAppId =>
      provider == TranslationProvider.baidu ||
      provider == TranslationProvider.youdao;

  bool get credentialOptional =>
      provider == TranslationProvider.custom &&
      protocol == TranslationProtocol.libreTranslate;

  TranslationProfile withTargetLanguage(String language) => TranslationProfile(
    id: id,
    name: name,
    provider: provider,
    endpoint: endpoint,
    model: model,
    appId: appId,
    sourceLanguage: sourceLanguage,
    targetLanguage: language,
    protocol: protocol,
    aiProfileId: aiProfileId,
    credentialRef: credentialRef,
    revision: revision,
    hasCredential: hasCredential,
    requestIntervalMs: requestIntervalMs,
  );

  TranslationProfile withStorage({
    required int revision,
    required String? credentialRef,
    required bool hasCredential,
  }) => TranslationProfile(
    id: id,
    name: name,
    provider: provider,
    endpoint: endpoint,
    model: model,
    appId: appId,
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    protocol: protocol,
    aiProfileId: aiProfileId,
    credentialRef: credentialRef,
    revision: revision,
    hasCredential: hasCredential,
    requestIntervalMs: requestIntervalMs,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'endpoint': endpoint,
    'model': model,
    'appId': appId,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'protocol': protocol.name,
    'aiProfileId': aiProfileId,
    'credentialRef': credentialRef,
    'revision': revision,
    'requestIntervalMs': requestIntervalMs,
  };

  factory TranslationProfile.fromJson(Map<String, Object?> json) {
    String field(String key) {
      final value = json[key];
      if (value is! String) throw const FormatException('invalid profile');
      return value;
    }

    String? optional(String key) {
      final value = json[key];
      if (value != null && value is! String) {
        throw const FormatException('invalid reference');
      }
      return value as String?;
    }

    final revision = json['revision'];
    if (revision is! int || revision < 1) {
      throw const FormatException('invalid revision');
    }
    final interval = json.containsKey('requestIntervalMs')
        ? json['requestIntervalMs']
        : defaultRequestIntervalMs;
    if (interval is! int || interval < 0 || interval > maxRequestIntervalMs) {
      throw const FormatException('invalid request interval');
    }
    return TranslationProfile(
      id: field('id'),
      name: field('name'),
      provider: TranslationProvider.values.byName(field('provider')),
      endpoint: field('endpoint'),
      model: field('model'),
      appId: field('appId'),
      sourceLanguage: field('sourceLanguage'),
      targetLanguage: field('targetLanguage'),
      protocol: TranslationProtocol.values.byName(field('protocol')),
      aiProfileId: optional('aiProfileId'),
      credentialRef: optional('credentialRef'),
      revision: revision,
      requestIntervalMs: interval,
    );
  }
}

final class TranslationSettings {
  TranslationSettings({
    List<TranslationProfile> profiles = const [],
    this.defaultProfileId,
    this.hasPendingCredentialCleanup = false,
  }) : profiles = List.unmodifiable(profiles);

  final List<TranslationProfile> profiles;
  final String? defaultProfileId;
  final bool hasPendingCredentialCleanup;
}

final class TranslationException implements Exception {
  const TranslationException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class TranslationResult {
  const TranslationResult({
    required this.text,
    this.inputTokens,
    this.outputTokens,
  });

  final String text;
  final int? inputTokens;
  final int? outputTokens;
}

abstract interface class TranslationSettingsRepository {
  Stream<TranslationSettings> watchSettings();
  Future<TranslationSettings> getSettings();
  Future<TranslationProfile> saveProfile(
    TranslationProfile profile, {
    String? secret,
    bool clearSecret = false,
  });
  Future<void> deleteProfile(String id, {required int expectedRevision});
  Future<void> setDefaultProfile(String id);
  Future<String?> readCredential(TranslationProfile profile);
  Future<void> clearCredentials();
}

abstract interface class TranslationGateway {
  Future<TranslationResult> translate({
    required TranslationProfile profile,
    required String text,
    String? secret,
    AiProfile? aiProfile,
    AiCancelToken? cancelToken,
  });
}
