import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/files/app_paths.dart';
import '../../../domain/web_books/web_book.dart';
import '../../../renderers/web/native_html_parser.dart';
import 'article_extractor.dart';

final class WebSnapshotStore {
  const WebSnapshotStore(this.paths);
  final AppPaths paths;

  Future<Directory> root(String bookId) async => Directory(
    p.join((await paths.libraryDirectory()).path, 'web', _id(bookId)),
  );
  Future<Directory> directory(String bookId, String snapshotId) async =>
      Directory(
        p.join((await root(bookId)).path, 'snapshots', _id(snapshotId)),
      );

  Future<void> discard(WebSnapshot snapshot) async {
    final path = await directory(snapshot.bookId, snapshot.id);
    if (await path.exists()) await path.delete(recursive: true);
  }

  Future<String?> notice(WebSnapshot snapshot) async {
    final manifest = await _manifest(snapshot);
    final missing = manifest['missingImages'] as int? ?? 0;
    final warnings = manifest['warnings'] as List? ?? const [];
    final message = [
      if (missing > 0) '$missing 张图片未保存',
      if (warnings.isNotEmpty) '网页含不支持的媒体或图片',
    ].join(' · ');
    return message.isEmpty ? null : message;
  }

  Future<bool> usesCurrentExtractor(WebSnapshot snapshot) async =>
      (await _manifest(snapshot))['extractorVersion'] ==
      ArticleExtractor.version;

  Future<Map<String, dynamic>> _manifest(WebSnapshot snapshot) async {
    final directory = await this.directory(snapshot.bookId, snapshot.id);
    final bytes = await File(
      p.join(directory.path, 'manifest.json'),
    ).readAsBytes();
    if (sha256.convert(bytes).toString() != snapshot.manifestHash) {
      throw const WebBookException('本地网页清单受损，请重新保存');
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<WebSnapshot> write({
    required WebChapter chapter,
    required ArticleExtraction article,
    required Uri finalUrl,
    required Map<String, Uint8List> images,
    String? etag,
    String? lastModified,
  }) async {
    final id = const Uuid().v4();
    final bookRoot = await root(chapter.bookId);
    final stage = Directory(p.join(bookRoot.path, 'staging', id));
    await stage.create(recursive: true);
    try {
      final text = await Isolate.run(
        () => NativeHtmlParser(
          imageBytes: const {},
        ).parse(article).chapters.single.text,
      );
      final hashes = <String, String>{};
      var size = utf8.encode(article.xhtml).length;
      for (final entry in images.entries) {
        final name = _resource(entry.key);
        final file = File(p.join(stage.path, name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
        hashes[name] = sha256.convert(entry.value).toString();
        size += entry.value.length;
      }
      final sourceRevision = sha256
          .convert(utf8.encode(jsonEncode([1, article.xhtml, hashes])))
          .toString();
      final textRevision = sha256
          .convert(utf8.encode('web-native-v1:$text'))
          .toString();
      final manifest = jsonEncode({
        'version': 1,
        'extractorVersion': ArticleExtractor.version,
        'title': article.title,
        'finalUrl': finalUrl.toString(),
        'images': hashes,
        'missingImages': article.images.length - images.length,
        'warnings': article.warnings.map((warning) => warning.name).toList(),
        'sourceRevision': sourceRevision,
        'textRevision': textRevision,
        'articleHash': sha256.convert(utf8.encode(article.xhtml)).toString(),
      });
      await File(
        p.join(stage.path, 'article.xhtml'),
      ).writeAsString(article.xhtml, flush: true);
      await File(
        p.join(stage.path, 'manifest.json'),
      ).writeAsString(manifest, flush: true);
      final target = await directory(chapter.bookId, id);
      await target.parent.create(recursive: true);
      await stage.rename(target.path);
      return WebSnapshot(
        id: id,
        chapterId: chapter.id,
        bookId: chapter.bookId,
        title: article.title,
        finalUrl: finalUrl.toString(),
        sourceRevision: sourceRevision,
        textRevision: textRevision,
        manifestHash: sha256.convert(utf8.encode(manifest)).toString(),
        byteSize: size + utf8.encode(manifest).length,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        etag: etag,
        lastModified: lastModified,
      );
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static String _id(String value) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(value)) {
      throw const WebBookException('网页书标识无效');
    }
    return value;
  }

  static String _resource(String value) {
    if (!RegExp(r'^resources/[a-f0-9]{64}$').hasMatch(value)) {
      throw const WebBookException('网页资源路径无效');
    }
    return value;
  }
}
