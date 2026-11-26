import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/tasks/task_cancellation.dart';
import '../../../domain/web_books/web_book.dart';

Uri webUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !const {'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const WebBookException('请输入完整的 http(s) 网页地址，不支持带账号密码的网址');
  }
  return uri.removeFragment();
}

final class WebResponse {
  const WebResponse(
    this.url,
    this.bytes,
    this.mime,
    this.charset,
    this.etag,
    this.lastModified, {
    this.notModified = false,
  });
  final Uri url;
  final Uint8List bytes;
  final String mime;
  final String? charset;
  final String? etag;
  final String? lastModified;
  final bool notModified;
  String get html {
    final encoding = charset == null ? null : Encoding.getByName(charset!);
    if (charset != null &&
        encoding == null &&
        charset!.toLowerCase() != 'utf-8') {
      throw const WebBookException('网页编码暂不支持，请使用 UTF-8 网页');
    }
    return (encoding ?? utf8).decode(bytes);
  }
}

class WebHttpClient {
  const WebHttpClient({this.timeout = const Duration(seconds: 30)});
  final Duration timeout;

  Future<WebResponse> fetch(
    Uri source, {
    required int maxBytes,
    required TaskCancelToken token,
    String? etag,
    String? lastModified,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    token.bind(() => client.close(force: true));
    try {
      return await (() async {
        var uri = webUrl(source.toString());
        for (var redirect = 0; redirect <= 5; redirect++) {
          token.throwIfCancelled();
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          if (uri.host == source.host) {
            if (etag != null) {
              request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
            }
            if (lastModified != null) {
              request.headers.set(
                HttpHeaders.ifModifiedSinceHeader,
                lastModified,
              );
            }
          }
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'PageSage/0.0.1 (offline reader)',
          );
          final response = await request.close();
          if (response.statusCode == 304 &&
              (etag != null || lastModified != null)) {
            return WebResponse(
              uri,
              Uint8List(0),
              '',
              null,
              etag,
              lastModified,
              notModified: true,
            );
          }
          if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null) throw const WebBookException('网页重定向缺少地址');
            uri = webUrl(uri.resolve(location).toString());
            await response.drain<void>();
            continue;
          }
          if (response.statusCode != 200) {
            throw WebBookException(
              '网页获取失败（HTTP ${response.statusCode}），已保存版本不受影响',
            );
          }
          final buffer = BytesBuilder(copy: false);
          await for (final bytes in response) {
            token.throwIfCancelled();
            if (buffer.length + bytes.length > maxBytes) {
              throw const WebBookException('网页或图片超过保存大小限制');
            }
            buffer.add(bytes);
          }
          final contentType = response.headers.contentType;
          return WebResponse(
            uri,
            buffer.takeBytes(),
            contentType?.mimeType ?? '',
            contentType?.charset,
            response.headers.value('etag'),
            response.headers.value('last-modified'),
          );
        }
        throw const WebBookException('网页重定向次数过多');
      })().timeout(timeout);
    } on TaskCancelledException {
      rethrow;
    } on WebBookException {
      rethrow;
    } on TimeoutException {
      throw const WebBookException('网页获取超时，请检查网络后重试');
    } on Object {
      token.throwIfCancelled();
      throw const WebBookException('无法连接或解码网页，请检查地址、网络和证书');
    } finally {
      client.close(force: true);
    }
  }
}
