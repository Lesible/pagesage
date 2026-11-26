import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../domain/translation/translation_models.dart';
import '../network/api_http_client.dart';
import '../security/secure_store.dart';
import 'ai_credential_guard.dart';
import 'app_database.dart';

const translationSettingsKey = 'translation.settings.v1';

final class DriftTranslationSettingsRepository
    implements TranslationSettingsRepository {
  DriftTranslationSettingsRepository(this._database, this._secrets);

  final AppDatabase _database;
  final SecureStore _secrets;
  late final _guard = AiCredentialGuard(_database);

  Future<void> prepareForRestore(Map<String, String> aiProfileIds) async {
    if (await _database.settingsDao.getValue(translationSettingsKey) == null) {
      return;
    }
    final stored = await _read();
    await _write(
      _StoredSettings(
        defaultId: stored.defaultId,
        profiles: [
          for (final profile in stored.profiles)
            TranslationProfile.fromJson({
              ...profile.toJson(),
              'aiProfileId':
                  aiProfileIds[profile.aiProfileId] ?? profile.aiProfileId,
              'credentialRef': null,
              'revision': profile.revision + 1,
            }),
        ],
      ),
    );
  }

  Future<_StoredSettings> _read() async {
    final value = await _database.settingsDao.getValue(translationSettingsKey);
    if (value == null) return _StoredSettings();
    try {
      final json = jsonDecode(value);
      if (json is! Map<String, Object?> || json['version'] != 1) {
        throw const FormatException('unknown version');
      }
      final profiles = json['profiles'];
      final pending = json['pendingCredentials'];
      final defaultId = json['defaultProfileId'];
      if (profiles is! List ||
          pending is! List ||
          (defaultId != null && defaultId is! String)) {
        throw const FormatException('invalid settings');
      }
      final result = _StoredSettings(
        profiles: profiles.map((entry) {
          if (entry is! Map<String, Object?>) {
            throw const FormatException('invalid profile');
          }
          return TranslationProfile.fromJson(entry);
        }).toList(),
        defaultId: defaultId as String?,
        pending: pending.map((entry) {
          if (entry is! String || !entry.startsWith('translation.secret.')) {
            throw const FormatException('invalid credential reference');
          }
          return entry;
        }).toSet(),
      );
      if (result.profiles.map((profile) => profile.id).toSet().length !=
              result.profiles.length ||
          (result.defaultId != null &&
              !result.profiles.any(
                (profile) => profile.id == result.defaultId,
              ))) {
        throw const FormatException('invalid profile identity');
      }
      for (final profile in result.profiles) {
        _validate(profile);
        final key = profile.credentialRef;
        if (key != null && !key.startsWith('translation.secret.')) {
          throw const FormatException('invalid credential reference');
        }
      }
      return result;
    } on Object {
      throw const TranslationException('翻译配置格式或版本不受支持，请保留数据并检查应用版本');
    }
  }

  Future<void> _write(_StoredSettings settings) =>
      _database.settingsDao.setValue(
        translationSettingsKey,
        jsonEncode({
          'version': 1,
          'profiles': settings.profiles
              .map((profile) => profile.toJson())
              .toList(),
          'defaultProfileId': settings.defaultId,
          'pendingCredentials': settings.pending.toList(),
        }),
        DateTime.now().millisecondsSinceEpoch,
      );

  Future<void> _cleanup(_StoredSettings stored) async {
    if (stored.pending.isEmpty) return;
    final previousCount = stored.pending.length;
    final active = stored.profiles
        .map((profile) => profile.credentialRef)
        .toSet();
    for (final key in stored.pending.toList()) {
      if (!active.contains(key)) {
        try {
          await _secrets.delete(key);
        } on Object {
          continue;
        }
      }
      stored.pending.remove(key);
    }
    if (stored.pending.length != previousCount) {
      await _write(stored);
    }
  }

  @override
  Stream<TranslationSettings> watchSettings() => _database.settingsDao
      .watchSettings()
      .map(
        (rows) => rows
            .where((row) => row.key == translationSettingsKey)
            .firstOrNull
            ?.value,
      )
      .distinct()
      .asyncMap((_) => getSettings());

  @override
  Future<TranslationSettings> getSettings() => _guard.run(() async {
    final stored = await _read();
    await _cleanup(stored);
    final profiles = <TranslationProfile>[];
    for (final profile in stored.profiles) {
      final key = profile.credentialRef;
      profiles.add(
        profile.withStorage(
          revision: profile.revision,
          credentialRef: key,
          hasCredential: key != null && await _secrets.hasValue(key),
        ),
      );
    }
    return TranslationSettings(
      profiles: profiles,
      defaultProfileId: stored.defaultId,
      hasPendingCredentialCleanup: stored.pending.isNotEmpty,
    );
  });

  @override
  Future<TranslationProfile> saveProfile(
    TranslationProfile profile, {
    String? secret,
    bool clearSecret = false,
  }) => _guard.run(() async {
    _validate(profile);
    final stored = await _read();
    await _cleanup(stored);
    final previous = stored.profiles
        .where((entry) => entry.id == profile.id)
        .firstOrNull;
    if (profile.revision != (previous?.revision ?? 0)) {
      throw const TranslationException('翻译配置已被修改，请重新读取后重试');
    }
    final newSecret = secret?.trim();
    final usesSecret = profile.provider != TranslationProvider.ai;
    final destinationChanged =
        previous != null &&
        (previous.provider != profile.provider ||
            previous.endpoint != profile.endpoint ||
            previous.appId != profile.appId ||
            previous.protocol != profile.protocol);
    if (usesSecret &&
        destinationChanged &&
        newSecret?.isNotEmpty != true &&
        !clearSecret &&
        previous.credentialRef != null) {
      throw const TranslationException('接口、应用或协议已改变，请重新输入凭据或清除旧凭据');
    }
    var key = !usesSecret || clearSecret ? null : previous?.credentialRef;
    if (usesSecret && !clearSecret && newSecret?.isNotEmpty == true) {
      key = 'translation.secret.${const Uuid().v4()}';
      stored.pending.add(key);
      await _write(stored);
      await _secrets.write(key, newSecret!);
      if (await _secrets.read(key) != newSecret) {
        throw const TranslationException('凭据未能安全保存，请重试');
      }
    }
    final saved = profile.withStorage(
      revision: profile.revision + 1,
      credentialRef: key,
      hasCredential: key != null && await _secrets.hasValue(key),
    );
    final previousKey = previous?.credentialRef;
    if (previousKey != null && previousKey != key) {
      stored.pending.add(previousKey);
    }
    final index = stored.profiles.indexWhere((entry) => entry.id == saved.id);
    if (index < 0) {
      stored.profiles.add(saved);
    } else {
      stored.profiles[index] = saved;
    }
    stored.defaultId ??= saved.id;
    await _write(stored);
    await _cleanup(stored);
    return saved;
  });

  @override
  Future<void> deleteProfile(String id, {required int expectedRevision}) =>
      _guard.run(() async {
        final stored = await _read();
        final profile = stored.profiles
            .where((entry) => entry.id == id)
            .firstOrNull;
        if (profile == null || profile.revision != expectedRevision) {
          throw const TranslationException('翻译配置已改变，请重新读取');
        }
        if (profile.credentialRef case final key?) stored.pending.add(key);
        stored.profiles.removeWhere((entry) => entry.id == id);
        if (stored.defaultId == id) {
          stored.defaultId = stored.profiles.firstOrNull?.id;
        }
        await _write(stored);
        await _cleanup(stored);
      });

  @override
  Future<void> setDefaultProfile(String id) => _guard.run(() async {
    final stored = await _read();
    if (!stored.profiles.any((entry) => entry.id == id)) {
      throw const TranslationException('翻译配置不存在，请重新读取');
    }
    stored.defaultId = id;
    await _write(stored);
  });

  @override
  Future<String?> readCredential(TranslationProfile profile) =>
      _guard.run(() async {
        final stored = await _read();
        final saved = stored.profiles
            .where((entry) => entry.id == profile.id)
            .firstOrNull;
        if (saved == null ||
            saved.revision != profile.revision ||
            jsonEncode(saved.toJson()) != jsonEncode(profile.toJson())) {
          throw const TranslationException('翻译配置已改变，请重新读取后重试');
        }
        final key = saved.credentialRef;
        return key == null ? null : _secrets.read(key);
      });

  @override
  Future<void> clearCredentials() => _guard.run(() async {
    final stored = await _read();
    final keys = {
      ...stored.pending,
      ...stored.profiles.map((entry) => entry.credentialRef).nonNulls,
    };
    for (final key in keys) {
      await _secrets.delete(key);
    }
  });

  void _validate(TranslationProfile profile) {
    if (profile.requestIntervalMs < 0 ||
        profile.requestIntervalMs > TranslationProfile.maxRequestIntervalMs) {
      throw const TranslationException('翻译请求间隔必须在 0～60 秒之间');
    }
    if (profile.id.isEmpty ||
        profile.name.trim().isEmpty ||
        !translationLanguages.containsKey(profile.sourceLanguage) ||
        !translationLanguages.containsKey(profile.targetLanguage) ||
        profile.targetLanguage == 'auto') {
      throw const TranslationException('请填写配置名称并选择有效的语言');
    }
    if (profile.provider == TranslationProvider.ai) {
      if (profile.aiProfileId?.isNotEmpty != true) {
        throw const TranslationException('请选择用于翻译的 AI 配置');
      }
      return;
    }
    try {
      apiBaseUri(profile.endpoint);
    } on ApiHttpException catch (error) {
      throw TranslationException(error.message);
    }
    if (profile.usesAppId && profile.appId.trim().isEmpty) {
      throw const TranslationException('请填写应用 ID');
    }
    if (profile.usesModel && profile.model.trim().isEmpty) {
      throw const TranslationException('请输入或选择翻译模型');
    }
  }
}

final class _StoredSettings {
  _StoredSettings({
    List<TranslationProfile>? profiles,
    this.defaultId,
    Set<String>? pending,
  }) : profiles = profiles ?? [],
       pending = pending ?? {};

  final List<TranslationProfile> profiles;
  String? defaultId;
  final Set<String> pending;
}
