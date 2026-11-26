import '../ai/ai_models.dart';
import 'translation_models.dart';

enum TranslationDisplayMode { original, bilingual, translated }

final class ReflowTranslation {
  const ReflowTranslation({required this.mode, required this.texts});
  final TranslationDisplayMode mode;
  final Map<String, String> texts;
}

final class TranslationSourcePart {
  const TranslationSourcePart(this.text, {this.protected = false});
  final String text;
  final bool protected;
}

final class ReadingTranslationUnit {
  ReadingTranslationUnit({
    required this.id,
    required this.original,
    required List<TranslationSourcePart> parts,
  }) : parts = List.unmodifiable(parts);
  final String id;
  final String original;
  final List<TranslationSourcePart> parts;
}

final class ReadingTranslationSource {
  ReadingTranslationSource({
    required this.bookId,
    required this.key,
    required this.label,
    required List<ReadingTranslationUnit> units,
  }) : units = List.unmodifiable(units);
  final String bookId;
  final String key;
  final String label;
  final List<ReadingTranslationUnit> units;
  int get characterCount =>
      units.fold(0, (sum, unit) => sum + unit.original.length);
}

final class TranslationPlan {
  const TranslationPlan({
    required this.profile,
    required this.fingerprint,
    this.aiProfile,
  });
  final TranslationProfile profile;
  final AiProfile? aiProfile;
  final String fingerprint;
}

final class SavedReadingTranslation {
  const SavedReadingTranslation({
    required this.id,
    required this.bookId,
    required this.sourceKey,
    required this.unitId,
    required this.original,
    required this.translated,
    required this.profileId,
    required this.profileLabel,
    required this.fingerprint,
    required this.targetLanguage,
    required this.createdAt,
  });
  final String id;
  final String bookId;
  final String sourceKey;
  final String unitId;
  final String original;
  final String translated;
  final String profileId;
  final String profileLabel;
  final String fingerprint;
  final String targetLanguage;
  final int createdAt;
}

abstract interface class ReadingTranslationRepository {
  Future<List<SavedReadingTranslation>> load(String bookId, String sourceKey);
  Future<void> save(SavedReadingTranslation translation);
}
