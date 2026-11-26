import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../domain/ai/ai_models.dart';
import '../../../domain/translation/translation_models.dart';
import '../../ai/application/ai_model_catalog.dart';
import 'translation_providers.dart';

final translationSettingsControllerProvider =
    Provider<TranslationSettingsController>((ref) {
      return TranslationSettingsController(ref);
    });

final class TranslationSettingsController {
  const TranslationSettingsController(this._ref);

  final Ref _ref;

  Future<TranslationProfile> save(
    TranslationProfile profile, {
    String? secret,
    bool clearSecret = false,
  }) => _ref
      .read(translationSettingsRepositoryProvider)
      .saveProfile(profile, secret: secret, clearSecret: clearSecret);

  Future<void> delete(TranslationProfile profile) => _ref
      .read(translationSettingsRepositoryProvider)
      .deleteProfile(profile.id, expectedRevision: profile.revision);

  Future<void> setDefault(String id) =>
      _ref.read(translationSettingsRepositoryProvider).setDefaultProfile(id);

  Future<TranslationResult> translate(
    String id,
    String text,
    AiCancelToken token,
  ) => _ref
      .read(translationServiceProvider)
      .translate(profileId: id, text: text, cancelToken: token);

  Future<List<String>> fetchModels(
    TranslationProfile draft,
    String secret,
    AiCancelToken token, {
    bool useSavedSecret = true,
  }) async {
    var key = secret;
    if (key.isEmpty && draft.revision > 0 && useSavedSecret) {
      final repository = _ref.read(translationSettingsRepositoryProvider);
      final settings = await repository.getSettings();
      final saved = settings.profiles
          .where((entry) => entry.id == draft.id)
          .firstOrNull;
      if (saved == null ||
          saved.revision != draft.revision ||
          saved.endpoint != draft.endpoint ||
          saved.provider != draft.provider ||
          saved.protocol != draft.protocol ||
          saved.appId != draft.appId) {
        throw const TranslationException('接口或配置已改变，请输入新密钥再拉取模型');
      }
      key = await repository.readCredential(saved) ?? '';
    }
    return _ref
        .read(aiModelCatalogProvider)
        .fetch(baseUrl: draft.endpoint, apiKey: key, cancelToken: token);
  }
}
