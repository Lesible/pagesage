import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/features/export/application/restore_database_preparation.dart';

import 'reading_translation_fixture.dart';

void main() {
  test(
    'restoring remaps AI translation references and detaches secret references without changing cached output identity',
    () async {
      final fixture = await ReadingTranslationFixture.create();
      addTearDown(fixture.dispose);
      final created = await fixture.ai.createProfile(name: '译文模型');
      final ai = await fixture.ai.updateProfile(
        AiProfile(
          id: created.id,
          name: created.name,
          baseUrl: 'http://127.0.0.1:1234/v1',
          model: 'model',
        ),
        apiKey: 'test-only-secret',
        expectedRevision: created.revision,
      );
      await fixture.settings.saveProfile(
        TranslationProfile(
          id: 'ai-translation',
          name: 'AI 翻译',
          provider: TranslationProvider.ai,
          endpoint: '',
          aiProfileId: ai.id,
          requestIntervalMs: 2500,
        ),
      );
      final direct = await fixture.settings.saveProfile(
        const TranslationProfile(
          id: 'baidu',
          name: '百度',
          provider: TranslationProvider.baidu,
          endpoint: 'https://fanyi-api.baidu.com/api/trans/vip/translate',
          appId: 'test-app',
          requestIntervalMs: 3500,
        ),
        secret: 'test-only-baidu-secret',
      );
      final before = await fixture.service.planFor('ai-translation');
      await prepareRestoredDatabase(fixture.database);
      final settings = await fixture.settings.getSettings();
      final restoredAi = settings.profiles.singleWhere(
        (profile) => profile.id == 'ai-translation',
      );
      expect(restoredAi.aiProfileId, isNot(ai.id));
      expect(restoredAi.requestIntervalMs, 2500);
      expect(await fixture.ai.getProfile(restoredAi.aiProfileId!), isNotNull);
      expect(
        (await fixture.service.planFor(restoredAi.id)).fingerprint,
        before.fingerprint,
      );
      final restoredDirect = settings.profiles.singleWhere(
        (profile) => profile.id == 'baidu',
      );
      expect(restoredDirect.credentialRef, isNull);
      expect(restoredDirect.requestIntervalMs, 3500);
      expect(restoredDirect.hasCredential, isFalse);
      expect(await fixture.settings.readCredential(restoredDirect), isNull);
      expect(
        await fixture.secrets.read(direct.credentialRef!),
        'test-only-baidu-secret',
      );
      expect(settings.hasPendingCredentialCleanup, isFalse);
    },
  );
}
