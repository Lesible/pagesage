// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/network/api_http_client.dart';
import '../../../core/security/security_keys.dart';
import '../../../core/security/secure_store.dart';
import '../../../domain/ai/ai_models.dart';

final aiModelCatalogProvider = Provider<AiModelCatalog>((ref) {
  return AiModelCatalog(
    profiles: ref.watch(aiProfileRepositoryProvider),
    secrets: ref.watch(secureStoreProvider),
  );
});

class AiModelCatalog {
  const AiModelCatalog({
    required AiProfileRepository profiles,
    required SecureStore secrets,
    ApiHttpClient http = const ApiHttpClient(),
  }) : _profiles = profiles,
       _secrets = secrets,
       _http = http;

  final AiProfileRepository _profiles;
  final SecureStore _secrets;
  final ApiHttpClient _http;

  Future<List<String>> fetch({
    required String baseUrl,
    String apiKey = '',
    String? profileId,
    AiCancelToken? cancelToken,
  }) async {
    final uri = openAiResourceUri(baseUrl, 'models');
    var secret = apiKey.trim();
    if (secret.isEmpty && profileId != null) {
      final saved = await _profiles.getProfile(profileId);
      if (saved == null || openAiResourceUri(saved.baseUrl, 'models') != uri) {
        throw const AiChatException('接口地址已改变，请先保存新地址和密钥，或重新输入密钥再拉取');
      }
      secret = await _secrets.read(aiProfileApiKeyStorageKey(profileId)) ?? '';
      final latest = await _profiles.getProfile(profileId);
      if (latest == null || latest.revision != saved.revision) {
        throw const AiChatException('AI 配置已改变，请重新拉取模型');
      }
    }
    try {
      final result = await _http.request(
        uri,
        method: 'GET',
        headers: {if (secret.isNotEmpty) 'Authorization': 'Bearer $secret'},
        cancelToken: cancelToken,
      );
      final rows = result['data'];
      if (rows is! List ||
          rows.any(
            (row) => row is! Map<String, Object?> || row['id'] is! String,
          )) {
        throw const AiChatException('模型列表格式不正确，可继续手动输入模型');
      }
      final ids =
          rows
              .map((row) => (row as Map<String, Object?>)['id'] as String)
              .where((id) => id.trim().isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      if (ids.isEmpty) throw const AiChatException('服务未返回可用模型，可继续手动输入');
      return ids;
    } on ApiHttpException catch (error) {
      throw AiChatException('${error.message}；可继续手动输入模型');
    }
  }
}
