import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/drift_ai_profile_repository.dart';
import 'package:pagesage/core/database/drift_translation_settings_repository.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/features/translation/application/translation_service.dart';
import 'package:pagesage/features/translation/data/http_translation_gateway.dart';

import 'reading_translation_fixture.dart';

void main() {
  test(
    'trial and reading requests share the same serialized cooldown',
    () async {
      final fixture = await ReadingTranslationFixture.create();
      addTearDown(fixture.dispose);
      final profile = (await fixture.settings.getSettings()).profiles.single;
      await fixture.settings.saveProfile(
        TranslationProfile.fromJson({
          ...profile.toJson(),
          'requestIntervalMs': 30,
        }),
      );
      final clock = Stopwatch()..start();
      final started = Completer<void>();
      final finishTrial = Completer<TranslationResult>();
      var trialFinishedAt = Duration.zero;
      var readingStartedAt = Duration.zero;
      fixture.gateway.respond = (text, token) async {
        if (text == 'trial') {
          started.complete();
          final result = await finishTrial.future;
          trialFinishedAt = clock.elapsed;
          return result;
        }
        readingStartedAt = clock.elapsed;
        return const TranslationResult(text: '阅读译文');
      };
      final plan = await fixture.service.planFor('service');
      final trial = fixture.service.translate(
        profileId: 'service',
        text: 'trial',
      );
      await started.future;
      final reading = fixture.service.translateWithPlan(plan, text: 'reading');
      expect(fixture.gateway.calls, ['trial']);
      finishTrial.complete(const TranslationResult(text: '试译结果'));
      expect((await trial).text, '试译结果');
      expect((await reading).text, '阅读译文');
      expect(fixture.gateway.calls, ['trial', 'reading']);
      expect(
        readingStartedAt - trialFinishedAt,
        greaterThanOrEqualTo(const Duration(milliseconds: 30)),
      );
    },
  );

  for (final delete in [false, true]) {
    test(
      'queued plan is revalidated after configuration ${delete ? 'deletion' : 'update'}',
      () async {
        final fixture = await ReadingTranslationFixture.create();
        addTearDown(fixture.dispose);
        final response = Completer<TranslationResult>();
        final started = Completer<void>();
        fixture.gateway.respond = (text, token) {
          started.complete();
          return response.future;
        };
        final plan = await fixture.service.planFor('service');
        final first = fixture.service.translateWithPlan(plan, text: 'first');
        await started.future;
        final queued = fixture.service.translateWithPlan(plan, text: 'queued');
        final rejected = expectLater(
          queued,
          throwsA(
            isA<TranslationException>().having(
              (error) => error.message,
              'changed profile',
              contains('配置已改变'),
            ),
          ),
        );
        if (delete) {
          await fixture.settings.deleteProfile(
            plan.profile.id,
            expectedRevision: plan.profile.revision,
          );
        } else {
          await fixture.settings.saveProfile(plan.profile);
        }
        response.complete(const TranslationResult(text: '第一段译文'));
        await first;
        await rejected;
        expect(fixture.gateway.calls, ['first']);
      },
    );
  }

  test(
    'AI translation references chosen profile independently of active AI and history',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer ai-secret');
        final body = jsonDecode(await utf8.decodeStream(request)) as Map;
        expect(body['model'], 'translation-model');
        expect(body['stream'], false);
        expect((body['messages'] as List).length, 2);
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '你好'},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final secrets = SecureStore.memory();
      final ai = DriftAiProfileRepository(database, secrets);
      addTearDown(ai.dispose);
      final first = await ai.createProfile(name: '聊天');
      await ai.setActiveProfile(first.id);
      final created = await ai.createProfile(name: '翻译专用');
      final selected = await ai.updateProfile(
        AiProfile(
          id: created.id,
          name: created.name,
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'translation-model',
        ),
        apiKey: 'ai-secret',
        expectedRevision: created.revision,
      );
      final settings = DriftTranslationSettingsRepository(database, secrets);
      await settings.saveProfile(
        TranslationProfile(
          id: 'translation',
          name: 'AI 翻译',
          provider: TranslationProvider.ai,
          endpoint: '',
          aiProfileId: selected.id,
        ),
      );
      final service = TranslationService(
        settings: settings,
        aiProfiles: ai,
        secrets: secrets,
        gateway: HttpTranslationGateway(),
      );
      expect(
        (await service.translate(profileId: 'translation', text: 'Hello')).text,
        '你好',
      );
      expect((await ai.getSettings()).activeProfileId, first.id);
      expect(await database.select(database.aiConversations).get(), isEmpty);
      await ai.deleteProfile(selected.id);
      await expectLater(
        service.translate(profileId: 'translation', text: 'Hello'),
        throwsA(
          isA<TranslationException>().having(
            (error) => error.message,
            'missing profile',
            contains('已被删除'),
          ),
        ),
      );
    },
  );
}
