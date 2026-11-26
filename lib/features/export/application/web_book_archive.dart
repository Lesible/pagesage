import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../core/files/app_paths.dart';
import '../../../core/tasks/task_cancellation.dart';
import '../../../domain/web_books/web_book.dart';
import '../../../renderers/web/web_document_loader.dart';
import '../../web_books/data/web_snapshot_store.dart';

final class WebArchiveFile {
  const WebArchiveFile(this.file, this.name, this.size, this.hash);
  final File file;
  final String name;
  final int size;
  final String hash;

  Map<String, Object> get metadata => {'size': size, 'sha256': hash};
}

final class WebBookArchive {
  const WebBookArchive(this.paths);
  final AppPaths paths;

  List<WebSnapshot> _snapshots(sqlite.Database database) => [
    for (final row in database.select('SELECT * FROM web_snapshots'))
      WebSnapshot(
        id: row['id'] as String,
        chapterId: row['chapter_id'] as String,
        bookId: row['book_id'] as String,
        title: row['title'] as String,
        finalUrl: row['final_url'] as String,
        sourceRevision: row['source_revision'] as String,
        textRevision: row['text_revision'] as String,
        byteSize: row['byte_size'] as int,
        createdAt: row['created_at'] as int,
        manifestHash: row['manifest_hash'] as String,
      ),
  ];

  Future<({bool hasBooks, List<WebArchiveFile> files})> collect(
    File frozenDatabase,
    TaskCancelToken? token,
  ) async {
    final database = sqlite.sqlite3.open(
      frozenDatabase.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final hasBooks = database
          .select("SELECT id FROM books WHERE format='web'")
          .isNotEmpty;
      final tables = database
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((row) => row['name'])
          .toSet();
      if (!tables.contains('web_snapshots')) {
        if (hasBooks) throw const FormatException('网络书快照表缺失');
        return (hasBooks: false, files: <WebArchiveFile>[]);
      }
      _validatePointers(database);
      final files = <WebArchiveFile>[];
      for (final snapshot in _snapshots(database)) {
        token?.throwIfCancelled();
        final directory = await WebSnapshotStore(
          paths,
        ).directory(snapshot.bookId, snapshot.id);
        await _verifyFiles(directory);
        await WebDocumentLoader(snapshot, directory.path).load(directory.path);
        for (final name in await _names(directory)) {
          final file = File(p.join(directory.path, name));
          final bytes = await file.readAsBytes();
          files.add(
            WebArchiveFile(
              file,
              'web/${snapshot.bookId}/snapshots/${snapshot.id}/$name',
              bytes.length,
              sha256.convert(bytes).toString(),
            ),
          );
        }
      }
      return (hasBooks: hasBooks, files: files);
    } finally {
      database.close();
    }
  }

  Future<void> stage({
    required Archive archive,
    required Map<String, dynamic> manifest,
    required File databaseFile,
    required Directory directory,
    TaskCancelToken? token,
  }) async {
    final database = sqlite.sqlite3.open(databaseFile.path);
    try {
      final books = database.select("SELECT id FROM books WHERE format='web'");
      _validatePointers(database);
      final rawFiles = manifest['webFiles'];
      if (books.isNotEmpty && (manifest['version'] != 2 || rawFiles is! Map)) {
        throw const FormatException('备份包含网络书，但没有离线网页资源');
      }
      if (rawFiles != null && rawFiles is! Map) {
        throw const FormatException('备份网页资源清单无效');
      }
      final files = rawFiles is Map ? rawFiles : const {};
      final seen = <String>{};
      var bytesTotal = 0;
      await directory.create(recursive: true);
      for (final entry in archive.files) {
        token?.throwIfCancelled();
        if (!entry.name.startsWith('web/')) continue;
        if (!entry.isFile && !entry.isSymbolicLink) continue;
        if (!RegExp(
              r'^web/[a-zA-Z0-9_-]{1,100}/snapshots/[a-zA-Z0-9_-]{1,100}/(manifest\.json|article\.xhtml|resources/[a-f0-9]{64})$',
            ).hasMatch(entry.name) ||
            entry.isSymbolicLink ||
            !seen.add(entry.name)) {
          throw const FormatException('备份网页路径无效或重复');
        }
        final metadata = files[entry.name];
        bytesTotal += entry.size;
        if (metadata is! Map ||
            metadata['size'] != entry.size ||
            entry.size > 120 * 1024 * 1024 ||
            bytesTotal > 2 * 1024 * 1024 * 1024 ||
            seen.length > 100000) {
          throw const FormatException('备份网页资源大小或清单无效');
        }
        final bytes = entry.content;
        if (bytes.length != entry.size ||
            sha256.convert(bytes).toString() != metadata['sha256']) {
          throw const FormatException('备份网页资源校验失败');
        }
        final file = File(p.join(directory.path, entry.name.substring(4)));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
      if (seen.length != files.length) {
        throw const FormatException('备份缺少网页正文或图片');
      }
      final expected = <String>{};
      for (final snapshot in _snapshots(database)) {
        token?.throwIfCancelled();
        final relative = '${snapshot.bookId}/snapshots/${snapshot.id}';
        if (!RegExp(
          r'^[a-zA-Z0-9_-]{1,100}/snapshots/[a-zA-Z0-9_-]{1,100}$',
        ).hasMatch(relative)) {
          throw const FormatException('备份网页标识无效');
        }
        final snapshotDirectory = Directory(p.join(directory.path, relative));
        await WebDocumentLoader(
          snapshot,
          snapshotDirectory.path,
        ).load(snapshotDirectory.path);
        expected.addAll(
          (await _names(
            snapshotDirectory,
          )).map((name) => 'web/$relative/$name'),
        );
      }
      if (expected.length != seen.length || !expected.containsAll(seen)) {
        throw const FormatException('备份网页资源与数据库不一致');
      }
      final library = await paths.libraryDirectory();
      for (final book in books) {
        final id = book['id'] as String;
        final root = await WebSnapshotStore(paths).root(id);
        if (!p.isWithin(library.path, root.path)) {
          throw const FormatException('网络书路径无效');
        }
        database.execute('UPDATE books SET library_file_path=? WHERE id=?', [
          root.path,
          id,
        ]);
      }
    } finally {
      database.close();
    }
  }

  void _validatePointers(sqlite.Database database) {
    final invalid = database.select(
      'SELECT c.id FROM web_chapters c LEFT JOIN web_snapshots s ON c.snapshot_id=s.id '
      'WHERE c.snapshot_id IS NOT NULL AND (s.id IS NULL OR s.book_id!=c.book_id OR s.chapter_id!=c.id) '
      'UNION ALL SELECT s.id FROM web_snapshots s '
      'LEFT JOIN web_chapters c ON c.id=s.chapter_id LEFT JOIN books b ON b.id=s.book_id '
      "WHERE c.id IS NULL OR b.id IS NULL OR b.format!='web' OR c.book_id!=s.book_id LIMIT 1",
    );
    if (invalid.isNotEmpty) throw const FormatException('备份网页章节与版本关联无效');
  }

  Future<List<String>> _names(Directory directory) async {
    final manifest = jsonDecode(
      await File(p.join(directory.path, 'manifest.json')).readAsString(),
    );
    if (manifest is! Map || manifest['images'] is! Map) {
      throw const FormatException('网页清单无效');
    }
    final images = (manifest['images'] as Map).keys;
    if (images.any(
      (name) =>
          name is! String ||
          !RegExp(r'^resources/[a-f0-9]{64}$').hasMatch(name),
    )) {
      throw const FormatException('网页图片路径无效');
    }
    return ['manifest.json', 'article.xhtml', ...images.cast<String>()];
  }

  Future<void> _verifyFiles(Directory directory) async {
    for (final path in [
      directory.path,
      p.dirname(directory.path),
      p.dirname(p.dirname(directory.path)),
      p.dirname(p.dirname(p.dirname(directory.path))),
      p.join(directory.path, 'manifest.json'),
      p.join(directory.path, 'article.xhtml'),
    ]) {
      if (await FileSystemEntity.isLink(path)) {
        throw const FormatException('网页备份不支持符号链接');
      }
    }
    for (final name in await _names(directory)) {
      if (await FileSystemEntity.isLink(p.join(directory.path, name)) ||
          await FileSystemEntity.isLink(p.join(directory.path, 'resources'))) {
        throw const FormatException('网页备份不支持符号链接');
      }
    }
  }
}
