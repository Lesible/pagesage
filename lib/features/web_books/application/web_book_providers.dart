import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/database/drift_web_book_repository.dart';
import '../../../core/files/file_providers.dart';
import '../../../domain/web_books/web_book.dart';
import '../data/web_snapshot_store.dart';
import 'web_book_service.dart';

final webBookRepositoryProvider = Provider<WebBookRepository>(
  (ref) => DriftWebBookRepository(ref.watch(appDatabaseProvider)),
);
final webSnapshotStoreProvider = Provider<WebSnapshotStore>(
  (ref) => WebSnapshotStore(ref.watch(appPathsProvider)),
);
final webBookServiceProvider = Provider<WebBookService>(
  (ref) => WebBookService(
    repository: ref.watch(webBookRepositoryProvider),
    store: ref.watch(webSnapshotStoreProvider),
    tasks: ref.watch(taskRepositoryProvider),
    cancellation: ref.watch(taskCancellationRegistryProvider),
    onChanged: (id) async {
      final book = await ref.read(bookRepositoryProvider).getBook(id);
      if (book != null) await ref.read(searchIndexerProvider).indexBook(book);
    },
  ),
);
final webChaptersProvider = StreamProvider.autoDispose
    .family<List<WebChapter>, String>(
      (ref, id) => ref.watch(webBookRepositoryProvider).watchChapters(id),
    );
