// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/security/security_keys.dart';
import '../../../core/security/secure_store.dart';
import '../../../domain/ai/ai_models.dart';
import '../../../domain/translation/translation_models.dart';
import '../../../domain/translation/reading_translation.dart';
import 'translation_request_scheduler.dart';

final class TranslationService {
  TranslationService({
    required TranslationSettingsRepository settings,
    required AiProfileRepository aiProfiles,
    required SecureStore secrets,
    required TranslationGateway gateway,
    TranslationRequestScheduler? scheduler,
  }) : _settings = settings,
       _aiProfiles = aiProfiles,
       _secrets = secrets,
       _gateway = gateway,
       _scheduler = scheduler ?? TranslationRequestScheduler();

  final TranslationSettingsRepository _settings;
  final AiProfileRepository _aiProfiles;
  final SecureStore _secrets;
  final TranslationGateway _gateway;
  final TranslationRequestScheduler _scheduler;

  Future<TranslationResult> translate({
    required String profileId,
    required String text,
    AiCancelToken? cancelToken,
  }) async {
    final plan = await planFor(profileId);
    return translateWithPlan(plan, text: text, cancelToken: cancelToken);
  }

  Future<TranslationPlan> planFor(
    String profileId, {
    String? targetLanguage,
  }) async {
    final settings = await _settings.getSettings();
    final stored = settings.profiles
        .where((entry) => entry.id == profileId)
        .firstOrNull;
    if (stored == null) throw const TranslationException('翻译配置不存在，请重新选择');
    final profile = targetLanguage == null
        ? stored
        : stored.withTargetLanguage(targetLanguage);
    AiProfile? ai;
    if (profile.provider == TranslationProvider.ai) {
      final id = profile.aiProfileId;
      ai = id == null ? null : await _aiProfiles.getProfile(id);
      if (ai == null) {
        throw const TranslationException('引用的 AI 配置已被删除，请在翻译设置中重新选择');
      }
    }
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'reading-translation-v1',
              profile.provider.name,
              profile.endpoint,
              profile.model,
              profile.appId,
              profile.protocol.name,
              profile.sourceLanguage,
              profile.targetLanguage,
              if (ai != null)
                [
                  ai.provider,
                  ai.baseUrl,
                  ai.model,
                  ai.temperature,
                  ai.maxTokens,
                  ai.systemPrompt,
                ],
            ]),
          ),
        )
        .toString();
    return TranslationPlan(
      profile: profile,
      aiProfile: ai,
      fingerprint: fingerprint,
    );
  }

  Future<TranslationResult> translateWithPlan(
    TranslationPlan plan, {
    required String text,
    AiCancelToken? cancelToken,
  }) => _scheduler.run(
    interval: Duration(milliseconds: plan.profile.requestIntervalMs),
    cancelToken: cancelToken,
    request: () => _translateNow(plan, text: text, cancelToken: cancelToken),
  );

  Future<TranslationResult> _translateNow(
    TranslationPlan plan, {
    required String text,
    AiCancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const AiChatCancelledException();
    }
    final current = await _settings.getSettings();
    final latestProfile = current.profiles
        .where((profile) => profile.id == plan.profile.id)
        .firstOrNull;
    if (latestProfile?.revision != plan.profile.revision) {
      throw const TranslationException('翻译配置已改变，请重新选择后重试');
    }
    final ai = plan.aiProfile;
    String? secret;
    if (ai == null) {
      secret = await _settings.readCredential(latestProfile!);
    } else {
      if (ai.baseUrl.trim().isEmpty || ai.model.trim().isEmpty) {
        throw const TranslationException('AI 配置缺少接口地址或模型，请先在 AI 菜单中完善');
      }
      secret = await _secrets.read(aiProfileApiKeyStorageKey(ai.id));
      if (secret?.isNotEmpty != true) {
        throw const TranslationException('AI 配置缺少密钥，请在 AI 菜单中保存');
      }
      final latest = await _aiProfiles.getProfile(ai.id);
      if (latest == null || latest.revision != ai.revision) {
        throw const TranslationException('AI 配置已改变，请重试');
      }
    }
    if (cancelToken?.isCancelled == true) {
      throw const AiChatCancelledException();
    }
    final result = await _gateway.translate(
      profile: plan.profile,
      text: text,
      secret: secret,
      aiProfile: ai,
      cancelToken: cancelToken,
    );
    if (result.text.trim().isEmpty) {
      throw const TranslationException('服务返回了空译文，请重试');
    }
    return result;
  }
}
