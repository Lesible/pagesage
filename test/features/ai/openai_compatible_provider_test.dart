import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/features/ai/data/openai_compatible_provider.dart';

void main() {
  late HttpServer server;
  late List<String> paths;
  late List<String?> authorization;
  late String responseBody;
  late int statusCode;

  setUp(() async {
    paths = <String>[];
    authorization = <String?>[];
    responseBody =
        '{"data":[{"id":"gpt-4o-mini"},'
        '{"id":"gpt-4o","name":"GPT-4o"},'
        '{"id":"gpt-4o-mini","name":"duplicate"}]}';
    statusCode = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      paths.add(request.uri.path);
      authorization.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.write(responseBody);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}/v1';

  test('reads the catalogue from the default /models endpoint', () async {
    final provider = OpenAiCompatibleProvider();

    final models = await provider.listModels(
      settings: AiSettings(baseUrl: baseUrl()),
      apiKey: 'test-secret',
    );

    expect(paths, ['/v1/models']);
    expect(authorization, ['Bearer test-secret']);
    expect(models.map((model) => model.id), ['gpt-4o', 'gpt-4o-mini']);
    expect(models.first.name, 'GPT-4o');
    expect(models.last.name, 'gpt-4o-mini');
    expect(models.every((model) => model.source == 'remote'), isTrue);
  });

  test('uses the editable catalogue URL when one is saved', () async {
    final provider = OpenAiCompatibleProvider();

    await provider.listModels(
      settings: AiSettings(
        baseUrl: baseUrl(),
        modelsUrl: 'http://127.0.0.1:${server.port}/custom/list',
      ),
      apiKey: 'test-secret',
    );

    expect(paths, ['/custom/list']);
  });

  test('explains a missing catalogue endpoint', () async {
    statusCode = HttpStatus.notFound;
    responseBody = '{"error":{"message":"not found"}}';
    final provider = OpenAiCompatibleProvider();

    await expectLater(
      provider.listModels(
        settings: AiSettings(baseUrl: baseUrl()),
        apiKey: 'test-secret',
      ),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.message,
          'message',
          contains('/models'),
        ),
      ),
    );
  });
}
