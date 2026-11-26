import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/drift_translation_settings_repository.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/translation/translation_models.dart';

void main() {
  late AppDatabase database;
  late SecureStore secrets;
  late DriftTranslationSettingsRepository repository;

  TranslationProfile profile({
    String id = 'one',
    int revision = 0,
    String endpoint = 'https://example.test/v1',
    int requestIntervalMs = TranslationProfile.defaultRequestIntervalMs,
  }) => TranslationProfile(
    id: id,
    name: '配置',
    provider: TranslationProvider.qwen,
    endpoint: endpoint,
    model: 'qwen-mt-flash',
    revision: revision,
    requestIntervalMs: requestIntervalMs,
  );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = SecureStore.memory();
    repository = DriftTranslationSettingsRepository(database, secrets);
  });

  tearDown(() => database.close());

  test(
    'profiles persist without secrets and default can be selected',
    () async {
      final first = await repository.saveProfile(
        profile(),
        secret: 'private-secret',
      );
      await repository.saveProfile(profile(id: 'two'), secret: 'other-secret');
      await repository.setDefaultProfile('two');
      final settings = await repository.getSettings();
      expect(settings.profiles, hasLength(2));
      expect(settings.defaultProfileId, 'two');
      expect(
        settings.profiles.every((profile) => profile.hasCredential),
        isTrue,
      );
      expect(await repository.readCredential(first), 'private-secret');
      final value = await database.settingsDao.getValue(translationSettingsKey);
      expect(value, isNot(contains('private-secret')));
      expect(value, isNot(contains('other-secret')));
    },
  );

  test('optimistic revision rejects stale updates and secret reads', () async {
    final old = await repository.saveProfile(profile(), secret: 'old');
    final next = await repository.saveProfile(old, secret: 'new');
    expect(next.revision, 2);
    await expectLater(
      repository.saveProfile(old, secret: 'stale'),
      throwsA(isA<TranslationException>()),
    );
    await expectLater(
      repository.readCredential(old),
      throwsA(isA<TranslationException>()),
    );
    expect(await repository.readCredential(next), 'new');
    expect(await secrets.read(old.credentialRef!), isNull);
  });

  test('changed endpoint cannot reuse old credentials', () async {
    final old = await repository.saveProfile(profile(), secret: 'old');
    await expectLater(
      repository.saveProfile(
        profile(revision: old.revision, endpoint: 'https://another.test/v1'),
      ),
      throwsA(isA<TranslationException>()),
    );
    expect(await repository.readCredential(old), 'old');
  });

  test(
    'delete removes secret and changes default without touching AI config',
    () async {
      await database.settingsDao.setValue('ai.test', 'untouched', 1);
      final first = await repository.saveProfile(profile(), secret: 'secret');
      await repository.saveProfile(profile(id: 'two'));
      await repository.deleteProfile(
        first.id,
        expectedRevision: first.revision,
      );
      expect((await repository.getSettings()).defaultProfileId, 'two');
      expect(await secrets.read(first.credentialRef!), isNull);
      expect(await database.settingsDao.getValue('ai.test'), 'untouched');
    },
  );

  test(
    'clear credential preserves metadata and secret update creates a new reference',
    () async {
      final saved = await repository.saveProfile(profile(), secret: 'secret');
      final cleared = await repository.saveProfile(saved, clearSecret: true);
      expect(cleared.hasCredential, isFalse);
      expect(cleared.credentialRef, isNull);
      expect(await secrets.read(saved.credentialRef!), isNull);
      expect(
        (await repository.getSettings()).profiles.single.model,
        'qwen-mt-flash',
      );
    },
  );

  test('unknown version and damaged JSON are visible errors', () async {
    for (final value in [
      'broken',
      '{"version":99}',
      '{"version":1,"profiles":[],"pendingCredentials":42}',
    ]) {
      await database.settingsDao.setValue(translationSettingsKey, value, 1);
      await expectLater(
        repository.getSettings(),
        throwsA(isA<TranslationException>()),
      );
    }
  });

  test(
    'interrupted secret write is cleaned but active references survive',
    () async {
      final saved = await repository.saveProfile(profile(), secret: 'active');
      const orphan = 'translation.secret.orphan';
      await secrets.write(orphan, 'uncommitted');
      final data =
          jsonDecode(
                (await database.settingsDao.getValue(translationSettingsKey))!,
              )
              as Map<String, Object?>;
      data['pendingCredentials'] = [orphan, saved.credentialRef];
      await database.settingsDao.setValue(
        translationSettingsKey,
        jsonEncode(data),
        1,
      );
      final settings = await repository.getSettings();
      expect(settings.profiles.single.hasCredential, isTrue);
      expect(await secrets.read(orphan), isNull);
      expect(await repository.readCredential(saved), 'active');
    },
  );

  test(
    'failed secure write preserves previous accepted configuration',
    () async {
      final broken = _FailingSecrets();
      final repo = DriftTranslationSettingsRepository(database, broken);
      final saved = await repo.saveProfile(profile(), secret: 'old');
      broken.fail = true;
      await expectLater(
        repo.saveProfile(saved, secret: 'new'),
        throwsA(isA<StateError>()),
      );
      broken.fail = false;
      expect((await repo.getSettings()).profiles.single.revision, 1);
      expect(await repo.readCredential(saved), 'old');
    },
  );

  test('real file database closes and reopens saved configuration', () async {
    final directory = await Directory.systemTemp.createTemp(
      'translation-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/settings.sqlite');
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase(file));
    final initial = DriftTranslationSettingsRepository(database, secrets);
    final saved = await initial.saveProfile(
      profile(requestIntervalMs: 2500),
      secret: 'persistent',
    );
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase(file));
    final reopened = DriftTranslationSettingsRepository(database, secrets);
    final restored = (await reopened.getSettings()).profiles.single;
    expect(restored.id, saved.id);
    expect(restored.requestIntervalMs, 2500);
    expect(await reopened.readCredential(saved), 'persistent');
  });

  test(
    'historical interval defaults without rewriting or losing credentials',
    () async {
      final saved = await repository.saveProfile(
        profile(),
        secret: 'persistent',
      );
      final historical = saved.toJson()..remove('requestIntervalMs');
      await database.settingsDao.setValue(
        translationSettingsKey,
        jsonEncode({
          'version': 1,
          'profiles': [historical],
          'defaultProfileId': saved.id,
          'pendingCredentials': <String>[],
        }),
        1,
      );
      final loaded = (await repository.getSettings()).profiles.single;
      expect(loaded.requestIntervalMs, 1000);
      expect(await repository.readCredential(loaded), 'persistent');
      final updated = await repository.saveProfile(
        profile(revision: loaded.revision, requestIntervalMs: 1500),
      );
      expect(updated.requestIntervalMs, 1500);
      expect(updated.credentialRef, loaded.credentialRef);
      expect(await repository.readCredential(updated), 'persistent');
    },
  );

  test(
    'invalid intervals are rejected before storing metadata or credentials',
    () async {
      for (final interval in [-1, 60001]) {
        await expectLater(
          repository.saveProfile(
            profile(requestIntervalMs: interval),
            secret: 'test-only-secret',
          ),
          throwsA(isA<TranslationException>()),
        );
      }
      expect(
        await database.settingsDao.getValue(translationSettingsKey),
        isNull,
      );
    },
  );

  test(
    'interrupted metadata commit cleans new key and preserves old key',
    () async {
      final saved = await repository.saveProfile(profile(), secret: 'accepted');
      await database.customStatement('''
      CREATE TRIGGER reject_translation_update BEFORE UPDATE ON app_settings
      WHEN NEW.key = '$translationSettingsKey'
        AND json_extract(NEW.value, '\$.profiles[0].revision') > 1
      BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END
    ''');
      await expectLater(
        repository.saveProfile(saved, secret: 'uncommitted'),
        throwsA(isA<Exception>()),
      );
      final value =
          jsonDecode(
                (await database.settingsDao.getValue(translationSettingsKey))!,
              )
              as Map;
      final pendingKey = (value['pendingCredentials'] as List).single as String;
      expect(await secrets.read(pendingKey), 'uncommitted');
      await database.customStatement('DROP TRIGGER reject_translation_update');
      expect((await repository.getSettings()).profiles.single.revision, 1);
      expect(await secrets.read(pendingKey), isNull);
      expect(await repository.readCredential(saved), 'accepted');
    },
  );

  test('failed secret cleanup remains visible and can be retried', () async {
    final broken = _FailingSecrets();
    final repo = DriftTranslationSettingsRepository(database, broken);
    final saved = await repo.saveProfile(profile(), secret: 'old');
    broken.failDelete = true;
    final updated = await repo.saveProfile(saved, secret: 'new');
    expect((await repo.getSettings()).hasPendingCredentialCleanup, isTrue);
    expect(await repo.readCredential(updated), 'new');
    expect(await broken.read(saved.credentialRef!), 'old');
    broken.failDelete = false;
    expect((await repo.getSettings()).hasPendingCredentialCleanup, isFalse);
    expect(await broken.read(saved.credentialRef!), isNull);
  });
}

final class _FailingSecrets extends SecureStore {
  _FailingSecrets() : super.memory();
  bool fail = false;
  bool failDelete = false;
  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('write failed');
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('delete failed');
    await super.delete(key);
  }
}
