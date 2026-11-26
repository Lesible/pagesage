import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/books/book.dart';
import '../../domain/web_books/web_book.dart';
import 'app_database.dart' as db;

final class DriftWebBookRepository implements WebBookRepository {
  const DriftWebBookRepository(this.database);
  final db.AppDatabase database;

  @override
  Future<Book> createBook({
    required String title,
    required String id,
    required String rootPath,
  }) async {
    if (title.trim().isEmpty) throw const WebBookException('请输入网络书名称');
    final now = DateTime.now().millisecondsSinceEpoch;
    final hash = sha256.convert(utf8.encode('pagesage:web:$id')).toString();
    await database
        .into(database.books)
        .insert(
          db.BooksCompanion.insert(
            id: id,
            title: title.trim(),
            format: 'web',
            libraryFilePath: rootPath,
            fileHash: hash,
            fileSize: 0,
            createdAt: now,
            updatedAt: now,
            indexingStatus: const Value('done'),
          ),
        );
    return Book(
      id: id,
      title: title.trim(),
      format: BookFormat.web,
      libraryFilePath: rootPath,
      fileHash: hash,
      fileSize: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Stream<List<WebChapter>> watchChapters(String bookId) =>
      (database.select(database.webChapters)
            ..where((row) => row.bookId.equals(bookId) & row.deletedAt.isNull())
            ..orderBy([
              (row) => OrderingTerm.asc(row.sortOrder),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .watch()
          .map((rows) => rows.map(_chapter).toList());

  @override
  Future<List<WebChapter>> chapters(String bookId) async =>
      (await (database.select(database.webChapters)
                ..where(
                  (row) => row.bookId.equals(bookId) & row.deletedAt.isNull(),
                )
                ..orderBy([
                  (row) => OrderingTerm.asc(row.sortOrder),
                  (row) => OrderingTerm.asc(row.id),
                ]))
              .get())
          .map(_chapter)
          .toList();

  @override
  Future<WebChapter> addChapter(String bookId, String url) =>
      database.transaction(() async {
        final book = await database.bookDao.getBook(bookId);
        if (book == null || book.format != 'web') {
          throw const WebBookException('网络书不存在');
        }
        final entries = await chapters(bookId);
        final existing = entries.where((entry) => entry.url == url).firstOrNull;
        if (existing != null) return existing;
        final id = const Uuid().v4();
        await database
            .into(database.webChapters)
            .insert(
              db.WebChaptersCompanion.insert(
                id: id,
                bookId: bookId,
                url: url,
                title: Uri.parse(url).host,
                sortOrder: entries.isEmpty ? 0 : entries.last.sortOrder + 1,
              ),
            );
        return WebChapter(
          id: id,
          bookId: bookId,
          url: url,
          title: Uri.parse(url).host,
          sortOrder: entries.isEmpty ? 0 : entries.last.sortOrder + 1,
          epoch: 0,
          state: 'pending',
        );
      });

  @override
  Future<WebChapter> beginCapture(String chapterId) =>
      database.transaction(() async {
        final row =
            await (database.select(database.webChapters)..where(
                  (row) => row.id.equals(chapterId) & row.deletedAt.isNull(),
                ))
                .getSingleOrNull();
        if (row == null) throw const WebBookException('章节已删除');
        await (database.update(
          database.webChapters,
        )..where((entry) => entry.id.equals(chapterId))).write(
          db.WebChaptersCompanion(
            epoch: Value(row.epoch + 1),
            state: const Value('fetching'),
            lastError: const Value(null),
          ),
        );
        return _chapter(row.copyWith(epoch: row.epoch + 1, state: 'fetching'));
      });

  @override
  Future<WebSnapshot?> snapshot(String id) async {
    final row = await (database.select(
      database.webSnapshots,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    return row == null
        ? null
        : WebSnapshot(
            id: row.id,
            chapterId: row.chapterId,
            bookId: row.bookId,
            title: row.title,
            finalUrl: row.finalUrl,
            sourceRevision: row.sourceRevision,
            textRevision: row.textRevision,
            byteSize: row.byteSize,
            createdAt: row.createdAt,
            manifestHash: row.manifestHash,
            etag: row.etag,
            lastModified: row.lastModified,
          );
  }

  @override
  Future<void> publish(
    WebChapter expected,
    WebSnapshot snapshot,
  ) => database.transaction(() async {
    if (snapshot.bookId != expected.bookId ||
        snapshot.chapterId != expected.id) {
      throw const WebBookException('网页版本与章节不匹配');
    }
    final changed =
        await (database.update(database.webChapters)..where(
              (row) =>
                  row.id.equals(expected.id) &
                  row.epoch.equals(expected.epoch) &
                  row.deletedAt.isNull() &
                  (expected.snapshotId == null
                      ? row.snapshotId.isNull()
                      : row.snapshotId.equals(expected.snapshotId!)),
            ))
            .write(
              db.WebChaptersCompanion(
                snapshotId: Value(snapshot.id),
                title: Value(snapshot.title),
                state: const Value('ready'),
                lastError: const Value(null),
                checkedAt: Value(snapshot.createdAt),
              ),
            );
    if (changed != 1) throw const WebBookException('章节已更新或删除，本次结果未发布');
    await database
        .into(database.webSnapshots)
        .insert(
          db.WebSnapshotsCompanion.insert(
            id: snapshot.id,
            chapterId: expected.id,
            bookId: expected.bookId,
            title: snapshot.title,
            finalUrl: snapshot.finalUrl,
            sourceRevision: snapshot.sourceRevision,
            textRevision: snapshot.textRevision,
            manifestHash: snapshot.manifestHash,
            byteSize: snapshot.byteSize,
            createdAt: snapshot.createdAt,
            etag: Value(snapshot.etag),
            lastModified: Value(snapshot.lastModified),
          ),
        );
    await database.customStatement(
      "UPDATE books SET file_size = (SELECT COALESCE(SUM(s.byte_size),0) FROM web_chapters c JOIN web_snapshots s ON c.snapshot_id=s.id WHERE c.book_id=? AND c.deleted_at IS NULL), indexing_status='pending', updated_at=? WHERE id=?",
      [expected.bookId, snapshot.createdAt, expected.bookId],
    );
    await database.customStatement(
      "UPDATE search_index_units SET requested_input_revision = ?, active_generation_id = NULL, state='pending' WHERE book_id = ?",
      [snapshot.id, expected.bookId],
    );
    await database
        .into(database.documentSources)
        .insertOnConflictUpdate(
          db.DocumentSourcesCompanion.insert(
            id: expected.id,
            bookId: expected.bookId,
            kind: 'web',
            address: expected.url,
            currentSourceRevision: Value(snapshot.sourceRevision),
            observedSize: Value(snapshot.byteSize),
            observedAt: snapshot.createdAt,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.createdAt,
          ),
        );
  });

  @override
  Future<void> finishCapture(WebChapter expected, {String? error}) async {
    await (database.update(database.webChapters)..where(
          (row) =>
              row.id.equals(expected.id) &
              row.epoch.equals(expected.epoch) &
              row.deletedAt.isNull(),
        ))
        .write(
          db.WebChaptersCompanion(
            state: Value(error == null ? 'ready' : 'failed'),
            lastError: Value(error),
            checkedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  @override
  Future<void> rename(String chapterId, String title) async {
    if (title.trim().isEmpty) throw const WebBookException('标题不能为空');
    await (database.update(database.webChapters)
          ..where((row) => row.id.equals(chapterId) & row.deletedAt.isNull()))
        .write(db.WebChaptersCompanion(customTitle: Value(title.trim())));
    final chapter = await (database.select(
      database.webChapters,
    )..where((row) => row.id.equals(chapterId))).getSingleOrNull();
    if (chapter != null) await _invalidate(chapter.bookId);
  }

  @override
  Future<void> reorder(String bookId, List<String> ids) =>
      database.transaction(() async {
        final current = await chapters(bookId);
        if (ids.toSet().length != ids.length ||
            ids.length != current.length ||
            !ids.toSet().containsAll(current.map((entry) => entry.id))) {
          throw const WebBookException('章节列表已改变，请重新读取');
        }
        for (var index = 0; index < ids.length; index++) {
          await (database.update(database.webChapters)
                ..where((row) => row.id.equals(ids[index])))
              .write(db.WebChaptersCompanion(sortOrder: Value(index)));
        }
        await _invalidate(bookId);
      });

  @override
  Future<void> deleteChapter(
    String chapterId,
  ) => database.transaction(() async {
    final chapter = await (database.select(
      database.webChapters,
    )..where((row) => row.id.equals(chapterId))).getSingleOrNull();
    if (chapter == null) return;
    await (database.update(
      database.webChapters,
    )..where((row) => row.id.equals(chapterId))).write(
      db.WebChaptersCompanion(
        deletedAt: Value(DateTime.now().millisecondsSinceEpoch),
        epoch: Value(chapter.epoch + 1),
      ),
    );
    await database.customStatement(
      "UPDATE search_index_units SET requested_input_revision=?, active_generation_id=NULL, state='pending' WHERE book_id=?",
      [const Uuid().v4(), chapter.bookId],
    );
    await database.customStatement(
      "UPDATE document_sources SET state='removed', updated_at=? WHERE id=?",
      [DateTime.now().millisecondsSinceEpoch, chapterId],
    );
    await _invalidate(chapter.bookId);
  });

  Future<void> _invalidate(String bookId) async {
    await database.customStatement(
      "UPDATE search_index_units SET requested_input_revision=?, active_generation_id=NULL, state='pending' WHERE book_id=?",
      [const Uuid().v4(), bookId],
    );
    await database.customStatement(
      "UPDATE books SET file_size=(SELECT COALESCE(SUM(s.byte_size),0) FROM web_chapters c JOIN web_snapshots s ON c.snapshot_id=s.id WHERE c.book_id=? AND c.deleted_at IS NULL), indexing_status='pending', updated_at=? WHERE id=?",
      [bookId, DateTime.now().millisecondsSinceEpoch, bookId],
    );
  }

  WebChapter _chapter(db.WebChapter row) => WebChapter(
    id: row.id,
    bookId: row.bookId,
    url: row.url,
    title: row.title,
    customTitle: row.customTitle,
    sortOrder: row.sortOrder,
    epoch: row.epoch,
    state: row.state,
    snapshotId: row.snapshotId,
    lastError: row.lastError,
    checkedAt: row.checkedAt,
  );
}
