import 'package:drift/drift.dart';

import '../../domain/translation/reading_translation.dart';
import 'app_database.dart';

final class DriftReadingTranslationRepository
    implements ReadingTranslationRepository {
  const DriftReadingTranslationRepository(this._database);
  final AppDatabase _database;

  @override
  Future<List<SavedReadingTranslation>> load(
    String bookId,
    String sourceKey,
  ) async {
    final rows =
        await (_database.select(_database.readingTranslations)
              ..where(
                (row) =>
                    row.bookId.equals(bookId) & row.sourceKey.equals(sourceKey),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]))
            .get();
    return rows
        .map(
          (row) => SavedReadingTranslation(
            id: row.id,
            bookId: row.bookId,
            sourceKey: row.sourceKey,
            unitId: row.unitId,
            original: row.original,
            translated: row.translated,
            profileId: row.profileId,
            profileLabel: row.profileLabel,
            fingerprint: row.fingerprint,
            targetLanguage: row.targetLanguage,
            createdAt: row.createdAt,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> save(SavedReadingTranslation translation) async {
    if (translation.translated.trim().isEmpty) {
      throw ArgumentError('Empty translation');
    }
    await _database
        .into(_database.readingTranslations)
        .insert(
          ReadingTranslationsCompanion.insert(
            id: translation.id,
            bookId: translation.bookId,
            sourceKey: translation.sourceKey,
            unitId: translation.unitId,
            original: translation.original,
            translated: translation.translated,
            profileId: translation.profileId,
            profileLabel: translation.profileLabel,
            fingerprint: translation.fingerprint,
            targetLanguage: translation.targetLanguage,
            createdAt: translation.createdAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }
}
