import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../domain/ai/ai_models.dart';
import 'ai_chat_service.dart';
import 'ai_context_source.dart';
import 'retrieval_context_source.dart';
import '../../web_books/application/web_reading_source.dart';
import '../../web_books/application/web_book_providers.dart';

final aiChatServiceProvider = Provider<AiChatService>((ref) {
  return AiChatService(
    settingsRepository: ref.watch(aiSettingsRepositoryProvider),
    conversationRepository: ref.watch(aiConversationRepositoryProvider),
    secureStore: ref.watch(secureStoreProvider),
  );
});

final aiConversationHistoryProvider = StreamProvider.autoDispose
    .family<List<AiConversation>, String>((ref, bookId) {
      return ref
          .watch(aiConversationRepositoryProvider)
          .watchConversations()
          .map(
            (rows) => rows
                .where((row) => row.bookId == bookId)
                .toList(growable: false),
          );
    });

/// Supplies the page or chapter text a context range needs.
final aiContextSourceProvider = Provider<AiContextSource>((ref) {
  return AiContextSource(
    webLoader: (locator) async {
      final snapshotId = locator.snapshotId;
      final snapshot = snapshotId == null
          ? null
          : await ref.read(webBookRepositoryProvider).snapshot(snapshotId);
      if (snapshot == null) throw const BookUnreadableException();
      final source = await WebReadingSource.resolve(
        bookId: snapshot.bookId,
        repository: ref.read(webBookRepositoryProvider),
        store: ref.read(webSnapshotStoreProvider),
        locator: locator,
      );
      if (source == null) {
        throw const BookUnreadableException();
      }
      return source.loader.load(source.path);
    },
  );
});

/// Supplies the passages a whole-book or whole-folder range is about.
final retrievalContextSourceProvider = Provider<RetrievalContextSource>((ref) {
  return RetrievalContextSource(
    searchRepository: ref.watch(searchRepositoryProvider),
    bookRepository: ref.watch(bookRepositoryProvider),
  );
});
