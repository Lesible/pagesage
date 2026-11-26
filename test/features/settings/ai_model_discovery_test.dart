import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/drift_ai_profile_repository.dart';
import 'package:pagesage/core/network/api_http_client.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/features/ai/application/ai_model_catalog.dart';

void main() {
  late HttpServer server;
  late AppDatabase database;
  late DriftAiProfileRepository profiles;
  late SecureStore secrets;
  late AiModelCatalog catalog;
  late Future<void> Function(HttpRequest request) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await handler(request);
      } finally {
        await request.response.close();
      }
    });
    database = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = SecureStore.memory();
    profiles = DriftAiProfileRepository(database, secrets);
    catalog = AiModelCatalog(profiles: profiles, secrets: secrets);
  });
  tearDown(() async {
    profiles.dispose();
    await database.close();
    await server.close(force: true);
  });

  test(
    'root normalizes to /v1/models and versioned/custom paths remain intact',
    () {
      expect(
        openAiResourceUri('https://example.test', 'models').path,
        '/v1/models',
      );
      expect(
        openAiResourceUri('https://example.test/v1/', 'models').path,
        '/v1/models',
      );
      expect(
        openAiResourceUri(
          'https://example.test/compatible-mode/v1/',
          'models',
        ).path,
        '/compatible-mode/v1/models',
      );
      expect(
        () => apiBaseUri('https://user:secret@example.test'),
        throwsA(isA<ApiHttpException>()),
      );
    },
  );

  test(
    'GET models authenticates and returns sorted unique IDs without saving',
    () async {
      handler = (request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/v1/models');
        expect(request.headers.value('authorization'), 'Bearer draft-secret');
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'z'},
              {'id': 'a'},
              {'id': 'z'},
            ],
          }),
        );
      };
      final result = await catalog.fetch(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'draft-secret',
      );
      expect(result, ['a', 'z']);
      expect(await profiles.listProfiles(), isEmpty);
    },
  );

  test('stored key may only be sent to the unchanged endpoint', () async {
    final profile = await profiles.createProfile(name: 'AI');
    final saved = await profiles.updateProfile(
      AiProfile(
        id: profile.id,
        name: profile.name,
        baseUrl: 'https://safe.example/v1',
        model: 'test',
      ),
      apiKey: 'saved-secret',
      expectedRevision: profile.revision,
    );
    var requests = 0;
    handler = (request) async {
      requests++;
    };
    await expectLater(
      catalog.fetch(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        profileId: saved.id,
      ),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.message,
          'error',
          contains('地址已改变'),
        ),
      ),
    );
    expect(requests, 0);
  });

  test('malformed and empty lists report manual entry fallback', () async {
    for (final response in [
      {'data': []},
      {
        'data': [
          {'id': 7},
        ],
      },
      {'unexpected': true},
    ]) {
      handler = (request) async {
        request.response.write(jsonEncode(response));
      };
      await expectLater(
        catalog.fetch(baseUrl: 'http://127.0.0.1:${server.port}'),
        throwsA(
          isA<AiChatException>().having(
            (error) => error.message,
            'fallback',
            contains('手动输入'),
          ),
        ),
      );
    }
  });

  test(
    'unsupported models API preserves safe error without server payload',
    () async {
      handler = (request) async {
        request.response.statusCode = 404;
        request.response.write('private-key');
      };
      await expectLater(
        catalog.fetch(baseUrl: 'http://127.0.0.1:${server.port}'),
        throwsA(
          isA<AiChatException>().having(
            (error) => error.message,
            'fallback',
            allOf(contains('手动输入'), isNot(contains('private-key'))),
          ),
        ),
      );
    },
  );
}
