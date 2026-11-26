import 'dart:io';

import 'package:drift/native.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/drift_ai_profile_repository.dart';
import 'package:pagesage/core/database/drift_reading_translation_repository.dart';
import 'package:pagesage/core/database/drift_translation_settings_repository.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/domain/translation/reading_translation.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/features/translation/application/reading_translation_controller.dart';
import 'package:pagesage/features/translation/application/translation_service.dart';

final class ReadingTranslationFixture {
  ReadingTranslationFixture._(this.directory, this.database);
  final Directory directory;
  AppDatabase database;
  final secrets = SecureStore.memory();
  final gateway = FakeReadingTranslator();
  late final ai = DriftAiProfileRepository(database, secrets);
  late final settings = DriftTranslationSettingsRepository(database, secrets);
  late final service = TranslationService(
    settings: settings,
    aiProfiles: ai,
    secrets: secrets,
    gateway: gateway,
  );
  DriftReadingTranslationRepository get repository =>
      DriftReadingTranslationRepository(database);

  static Future<ReadingTranslationFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'pagesage-translation-',
    );
    final fixture = ReadingTranslationFixture._(
      directory,
      AppDatabase.forTesting(
        NativeDatabase(File('${directory.path}/test.sqlite')),
      ),
    );
    await fixture.database
        .into(fixture.database.books)
        .insert(
          BooksCompanion.insert(
            id: 'book',
            title: 'Fixture',
            format: 'pdf',
            libraryFilePath: '/fixture.pdf',
            fileHash: 'file-v1',
            fileSize: 1,
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await fixture.settings.saveProfile(
      const TranslationProfile(
        id: 'service',
        name: '测试翻译',
        provider: TranslationProvider.custom,
        protocol: TranslationProtocol.libreTranslate,
        endpoint: 'http://127.0.0.1:1234/translate',
        requestIntervalMs: 0,
      ),
    );
    return fixture;
  }

  ReadingTranslationController controller({
    ReadingTranslationRepository? repository,
  }) => ReadingTranslationController(
    repository: repository ?? this.repository,
    service: service,
  );

  Future<void> reopen() async {
    await database.close();
    database = AppDatabase.forTesting(
      NativeDatabase(File('${directory.path}/test.sqlite')),
    );
    await database.customSelect('SELECT 1').get();
  }

  Future<void> dispose() async {
    ai.dispose();
    await database.close();
    await directory.delete(recursive: true);
  }
}

ReadingTranslationSource translationSource({
  String key = 'snapshot-one',
  List<String> texts = const ['First paragraph', 'Second paragraph'],
}) => ReadingTranslationSource(
  bookId: 'book',
  key: key,
  label: '来源 $key',
  units: [
    for (var index = 0; index < texts.length; index++)
      ReadingTranslationUnit(
        id: '0:$index',
        original: texts[index],
        parts: [TranslationSourcePart(texts[index])],
      ),
  ],
);

final class FakeReadingTranslator implements TranslationGateway {
  final List<String> calls = [];
  final List<String> targets = [];
  Future<TranslationResult> Function(String text, AiCancelToken? token)?
  respond;
  @override
  Future<TranslationResult> translate({
    required TranslationProfile profile,
    required String text,
    String? secret,
    AiProfile? aiProfile,
    AiCancelToken? cancelToken,
  }) async {
    calls.add(text);
    targets.add(profile.targetLanguage);
    return respond?.call(text, cancelToken) ??
        TranslationResult(text: '译文：$text');
  }
}
