import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../domain/translation/translation_models.dart';
import '../../../domain/translation/reading_translation.dart';
import '../../../core/database/drift_reading_translation_repository.dart';
import '../../ocr/application/ocr_providers.dart';
import '../data/reading_translation_source.dart';
import '../data/http_translation_gateway.dart';
import 'translation_service.dart';

final translationSettingsProvider = StreamProvider<TranslationSettings>((ref) {
  return ref.watch(translationSettingsRepositoryProvider).watchSettings();
});

final translationGatewayProvider = Provider<TranslationGateway>((ref) {
  return HttpTranslationGateway();
});

final translationServiceProvider = Provider<TranslationService>((ref) {
  return TranslationService(
    settings: ref.watch(translationSettingsRepositoryProvider),
    aiProfiles: ref.watch(aiProfileRepositoryProvider),
    secrets: ref.watch(secureStoreProvider),
    gateway: ref.watch(translationGatewayProvider),
  );
});

final readingTranslationRepositoryProvider =
    Provider<ReadingTranslationRepository>((ref) {
      return DriftReadingTranslationRepository(ref.watch(appDatabaseProvider));
    });

final readingTranslationSourceLoaderProvider =
    Provider<ReadingTranslationSourceLoader>((ref) {
      return ReadingTranslationSourceLoader(
        ocrStore: ref.watch(ocrPageStoreProvider),
      );
    });
