import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/ai/ai_models.dart';

final class ApiHttpException implements Exception {
  const ApiHttpException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

Uri apiBaseUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const ApiHttpException('请输入不含账号、查询参数或片段的完整 http(s) 接口地址');
  }
  return uri;
}

Uri openAiResourceUri(String baseUrl, String resource) {
  final uri = apiBaseUri(baseUrl);
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri.replace(path: '${path.isEmpty ? '/v1' : path}/$resource');
}

class ApiHttpClient {
  const ApiHttpClient({
    this.timeout = const Duration(seconds: 45),
    this.maxResponseBytes = 4 * 1024 * 1024,
  });

  final Duration timeout;
  final int maxResponseBytes;

  Future<Map<String, Object?>> request(
    Uri uri, {
    String method = 'POST',
    Map<String, String> headers = const {},
    Map<String, Object?>? jsonBody,
    Map<String, String>? formBody,
    AiCancelToken? cancelToken,
  }) async {
    apiBaseUri(uri.toString());
    final client = HttpClient()..connectionTimeout = timeout;
    cancelToken?.bind(() => client.close(force: true));
    try {
      if (cancelToken?.isCancelled == true) {
        throw const AiChatCancelledException();
      }
      return await (() async {
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (formBody != null) {
          request.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
            charset: 'utf-8',
          );
          request.write(Uri(queryParameters: formBody).query);
        } else if (jsonBody != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(jsonBody));
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw ApiHttpException(switch (response.statusCode) {
            401 || 403 => '凭据无效或没有访问权限',
            404 => '接口或模型不存在，请检查地址和模型',
            429 => '服务限流或额度不足，请稍后重试',
            >= 500 => '服务暂不可用，请稍后重试',
            >= 300 && < 400 => '接口发生重定向，请填写最终接口地址',
            _ => '请求失败（HTTP ${response.statusCode}）',
          }, statusCode: response.statusCode);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const ApiHttpException('服务响应过大，请缩小请求范围');
          }
          bytes.addAll(chunk);
        }
        if (cancelToken?.isCancelled == true) {
          throw const AiChatCancelledException();
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, Object?>) {
          throw const ApiHttpException('服务响应格式不正确');
        }
        return decoded;
      })().timeout(timeout);
    } on TimeoutException {
      throw const ApiHttpException('请求超时，服务可能已处理本次请求，请按需重试');
    } on SocketException {
      if (cancelToken?.isCancelled == true) {
        throw const AiChatCancelledException();
      }
      throw const ApiHttpException('网络连接失败，请检查接口地址和网络');
    } on HttpException {
      if (cancelToken?.isCancelled == true) {
        throw const AiChatCancelledException();
      }
      throw const ApiHttpException('网络连接中断，请按需重试');
    } on HandshakeException {
      throw const ApiHttpException('安全连接失败，请检查证书和接口地址');
    } on FormatException {
      throw const ApiHttpException('服务响应不是有效 JSON');
    } finally {
      client.close(force: true);
    }
  }
}
