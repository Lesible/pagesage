import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/network/api_http_client.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/features/translation/data/http_translation_gateway.dart';

void main() {
  late HttpServer server;
  late Uri endpoint;
  late HttpTranslationGateway gateway;
  late Future<void> Function(HttpRequest request) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/v1');
    gateway = HttpTranslationGateway(
      salt: () => 'salt',
      timestamp: () => 1700000000,
    );
    server.listen((request) async {
      try {
        await handler(request);
      } finally {
        await request.response.close();
      }
    });
  });

  tearDown(() => server.close(force: true));

  TranslationProfile profile(
    TranslationProvider provider, {
    TranslationProtocol protocol = TranslationProtocol.openAi,
    String source = 'auto',
  }) => TranslationProfile(
    id: 'test',
    name: 'Test',
    provider: provider,
    endpoint: endpoint.toString(),
    model: provider.defaultModel.isEmpty
        ? 'custom-model'
        : provider.defaultModel,
    appId: 'app',
    protocol: protocol,
    sourceLanguage: source,
  );

  Future<Map<String, Object?>> jsonBody(HttpRequest request) async =>
      jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;

  void reply(HttpRequest request, Object value) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
  }

  test('Baidu posts UTF-8 form and correct MD5 signature', () async {
    handler = (request) async {
      final form = Uri.splitQueryString(await utf8.decodeStream(request));
      expect(form['q'], 'Hello 你好');
      expect(form['appid'], 'app');
      expect(form['to'], 'zh');
      expect(
        form['sign'],
        md5.convert(utf8.encode('appHello 你好saltsecret')).toString(),
      );
      reply(request, {
        'trans_result': [
          {'dst': '你好'},
        ],
      });
    };
    final result = await gateway.translate(
      profile: profile(TranslationProvider.baidu),
      text: 'Hello 你好',
      secret: 'secret',
    );
    expect(result.text, '你好');
  });

  test('Youdao v3 signs Unicode code points, timestamp and app key', () async {
    const text = '😀abcdefghijABCDEFGHIJuvwxyz';
    final runes = text.runes.toList();
    final input =
        '${String.fromCharCodes(runes.take(10))}${runes.length}${String.fromCharCodes(runes.skip(runes.length - 10))}';
    handler = (request) async {
      final form = Uri.splitQueryString(await utf8.decodeStream(request));
      expect(form['signType'], 'v3');
      expect(form['to'], 'zh-CHS');
      expect(form['strict'], 'true');
      expect(
        form['sign'],
        sha256
            .convert(utf8.encode('app${input}salt1700000000secret'))
            .toString(),
      );
      reply(request, {
        'errorCode': '0',
        'translation': ['译文'],
      });
    };
    expect(
      (await gateway.translate(
        profile: profile(TranslationProvider.youdao),
        text: text,
        secret: 'secret',
      )).text,
      '译文',
    );
  });

  test(
    'DeepL uses plan endpoint, auth prefix and correct source language',
    () async {
      handler = (request) async {
        expect(request.headers.value('authorization'), 'DeepL-Auth-Key secret');
        final body = await jsonBody(request);
        expect(body['source_lang'], 'EN');
        expect(body['target_lang'], 'ZH-HANS');
        expect(body['text'], ['Hello']);
        reply(request, {
          'translations': [
            {'text': '你好'},
          ],
        });
      };
      expect(
        (await gateway.translate(
          profile: profile(TranslationProvider.deepl, source: 'en'),
          text: 'Hello',
          secret: 'secret',
        )).text,
        '你好',
      );
    },
  );

  test(
    'Qwen uses one user message and translation_options without chat parameters',
    () async {
      handler = (request) async {
        expect(request.uri.path, '/v1/chat/completions');
        expect(request.headers.value('authorization'), 'Bearer secret');
        final body = await jsonBody(request);
        expect(body['model'], 'qwen-mt-flash');
        expect(body['translation_options'], {
          'source_lang': 'auto',
          'target_lang': 'Chinese',
        });
        expect(body['messages'], [
          {'role': 'user', 'content': 'Hello'},
        ]);
        expect(body.containsKey('temperature'), isFalse);
        reply(request, {
          'choices': [
            {
              'message': {'content': '你好'},
              'finish_reason': 'stop',
            },
          ],
          'usage': {'prompt_tokens': 2, 'completion_tokens': 3},
        });
      };
      final result = await gateway.translate(
        profile: profile(TranslationProvider.qwen),
        text: 'Hello',
        secret: 'secret',
      );
      expect(result.text, '你好');
      expect(result.inputTokens, 2);
      expect(result.outputTokens, 3);
    },
  );

  test(
    'Tencent uses current TokenHub model and target in user instruction',
    () async {
      expect(
        TranslationProvider.tencent.defaultEndpoint,
        'https://tokenhub.tencentmaas.com/v1',
      );
      handler = (request) async {
        final body = await jsonBody(request);
        expect(body['model'], 'hy-mt3-plus');
        final messages = body['messages'] as List;
        expect(messages, hasLength(1));
        expect((messages.single as Map)['content'], contains('简体中文'));
        reply(request, {
          'choices': [
            {
              'message': {'content': '你好'},
            },
          ],
        });
      };
      expect(
        (await gateway.translate(
          profile: profile(TranslationProvider.tencent),
          text: 'Hello',
          secret: 'secret',
        )).text,
        '你好',
      );
    },
  );

  test('custom OpenAI provider sends protected translation request', () async {
    handler = (request) async {
      final body = await jsonBody(request);
      expect(body['model'], 'custom-model');
      expect((body['messages'] as List).length, 2);
      reply(request, {
        'choices': [
          {
            'message': {'content': '你好'},
          },
        ],
      });
    };
    expect(
      (await gateway.translate(
        profile: profile(TranslationProvider.custom),
        text: 'Hello',
        secret: 'secret',
      )).text,
      '你好',
    );
  });

  test('custom LibreTranslate supports keyless local API', () async {
    handler = (request) async {
      final body = await jsonBody(request);
      expect(body['q'], 'Hello');
      expect(body['target'], 'zh');
      expect(body.containsKey('api_key'), isFalse);
      expect(request.headers.value('authorization'), isNull);
      reply(request, {'translatedText': '你好'});
    };
    expect(
      (await gateway.translate(
        profile: profile(
          TranslationProvider.custom,
          protocol: TranslationProtocol.libreTranslate,
        ),
        text: 'Hello',
      )).text,
      '你好',
    );
  });

  test('provider errors do not leak returned secrets or source text', () async {
    handler = (request) async {
      await request.drain<void>();
      reply(request, {
        'error_code': '54003',
        'error_msg': 'secret private-book',
      });
    };
    await expectLater(
      gateway.translate(
        profile: profile(TranslationProvider.baidu),
        text: 'private-book',
        secret: 'secret',
      ),
      throwsA(
        isA<TranslationException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('54003'),
            isNot(contains('secret')),
            isNot(contains('private-book')),
          ),
        ),
      ),
    );
  });

  test(
    'empty and truncated model replies fail rather than pretending success',
    () async {
      for (final choice in [
        {
          'message': {'content': ''},
        },
        {
          'message': {'content': 'partial'},
          'finish_reason': 'length',
        },
      ]) {
        handler = (request) async {
          await request.drain<void>();
          reply(request, {
            'choices': [choice],
          });
        };
        await expectLater(
          gateway.translate(
            profile: profile(TranslationProvider.qwen),
            text: 'Hello',
            secret: 'secret',
          ),
          throwsA(isA<TranslationException>()),
        );
      }
    },
  );

  test(
    'HTTP errors are safe and do not follow redirects with credentials',
    () async {
      handler = (request) async {
        await request.drain<void>();
        request.response.statusCode = 302;
        request.response.headers.set('location', '${endpoint.origin}/stolen');
        request.response.write('secret');
      };
      await expectLater(
        gateway.translate(
          profile: profile(TranslationProvider.deepl),
          text: 'Hello',
          secret: 'secret',
        ),
        throwsA(
          isA<TranslationException>().having(
            (error) => error.message,
            'redirect',
            contains('重定向'),
          ),
        ),
      );
    },
  );

  test('network timeout and cancellation release request', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    handler = (request) async {
      started.complete();
      await gate.future;
    };
    final token = AiCancelToken();
    final pending = gateway.translate(
      profile: profile(TranslationProvider.deepl),
      text: 'Hello',
      secret: 'secret',
      cancelToken: token,
    );
    final checked = expectLater(
      pending,
      throwsA(isA<AiChatCancelledException>()),
    );
    await started.future;
    token.cancel();
    gate.complete();
    await checked;
  });

  test('bounded network client rejects oversized JSON', () async {
    handler = (request) async {
      await request.drain<void>();
      reply(request, {'body': 'x' * 100});
    };
    await expectLater(
      const ApiHttpClient(maxResponseBytes: 16).request(endpoint),
      throwsA(isA<ApiHttpException>()),
    );
  });

  test(
    'network client times out without automatically repeating request',
    () async {
      var count = 0;
      final gate = Completer<void>();
      handler = (request) async {
        count++;
        await gate.future;
      };
      try {
        await expectLater(
          const ApiHttpClient(
            timeout: Duration(milliseconds: 100),
          ).request(endpoint),
          throwsA(
            isA<ApiHttpException>().having(
              (error) => error.message,
              'timeout',
              contains('超时'),
            ),
          ),
        );
        expect(count, 1);
      } finally {
        gate.complete();
      }
    },
  );

  test(
    'provider-specific byte and character limits reject before networking',
    () async {
      var count = 0;
      handler = (request) async {
        count++;
      };
      await expectLater(
        gateway.translate(
          profile: profile(TranslationProvider.baidu),
          text: '字' * 2001,
          secret: 'secret',
        ),
        throwsA(
          isA<TranslationException>().having(
            (error) => error.message,
            'byte limit',
            contains('6000 字节'),
          ),
        ),
      );
      await expectLater(
        gateway.translate(
          profile: profile(TranslationProvider.youdao),
          text: 'a' * 5001,
          secret: 'secret',
        ),
        throwsA(
          isA<TranslationException>().having(
            (error) => error.message,
            'character limit',
            contains('5000 字符'),
          ),
        ),
      );
      expect(count, 0);
    },
  );
}
