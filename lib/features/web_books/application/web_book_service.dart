import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../core/tasks/task_cancellation.dart';
import '../../../core/tasks/task_models.dart';
import '../../../domain/books/book.dart';
import '../../../domain/web_books/web_book.dart';
import '../../../renderers/common/image_size.dart';
import '../../../renderers/web/web_document_loader.dart';
import '../data/article_extractor.dart';
import '../data/web_http_client.dart';
import '../data/web_snapshot_store.dart';

final class WebBookService {
  WebBookService({
    required this.repository,
    required this.store,
    required this.tasks,
    required this.cancellation,
    required this.onChanged,
    this.http = const WebHttpClient(),
  });
  final WebBookRepository repository;
  final WebSnapshotStore store;
  final TaskRepository tasks;
  final TaskCancellationRegistry cancellation;
  final Future<void> Function(String bookId) onChanged;
  final WebHttpClient http;
  final Map<String, Future<WebSnapshot?>> _pending = {};

  Future<Book> create(String title) async {
    if (title.trim().isEmpty || title.trim().length > 200) {
      throw const WebBookException('请输入不超过 200 字的书名');
    }
    final id = const Uuid().v4();
    final root = await store.root(id);
    await root.create(recursive: true);
    try {
      return await repository.createBook(
        title: title,
        id: id,
        rootPath: root.path,
      );
    } on Object {
      if (await root.exists()) await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<WebChapter> add(String bookId, String url) async {
    final chapter = await repository.addChapter(bookId, webUrl(url).toString());
    if (chapter.snapshotId == null) await refresh(chapter);
    return chapter;
  }

  Future<WebSnapshot?> refresh(
    WebChapter chapter, {
    TaskCancelToken? batchToken,
  }) {
    final existing = _pending[chapter.id];
    if (existing != null) return existing;
    final future = _capture(chapter, batchToken);
    _pending[chapter.id] = future;
    return future.whenComplete(() {
      if (identical(_pending[chapter.id], future)) _pending.remove(chapter.id);
    });
  }

  Future<WebSnapshot?> _capture(
    WebChapter chapter,
    TaskCancelToken? batchToken,
  ) async {
    final task = await tasks.saveTask(
      type: PageSageTaskType.webCapture,
      status: PageSageTaskStatus.running,
      bookId: chapter.bookId,
      sourcePath: chapter.id,
      message: '正在保存网页',
    );
    final token = cancellation.register(task.id);
    batchToken?.bind(token.cancel);
    WebChapter? expected;
    WebSnapshot? candidate;
    var published = false;
    try {
      token.throwIfCancelled();
      expected = await repository.beginCapture(chapter.id);
      final previous = expected.snapshotId == null
          ? null
          : await repository.snapshot(expected.snapshotId!);
      var useValidators = false;
      var previousReadable = false;
      var previousCurrentExtraction = false;
      if (previous != null) {
        try {
          final directory = await store.directory(previous.bookId, previous.id);
          await WebDocumentLoader(
            previous,
            directory.path,
          ).load(directory.path);
          previousReadable = true;
          previousCurrentExtraction = await store.usesCurrentExtractor(
            previous,
          );
          useValidators =
              previousCurrentExtraction && await store.notice(previous) == null;
        } on Object {
          useValidators = false;
        }
      }
      token.throwIfCancelled();
      final response = await http.fetch(
        webUrl(expected.url),
        maxBytes: 10 * 1024 * 1024,
        token: token,
        etag: useValidators ? previous?.etag : null,
        lastModified: useValidators ? previous?.lastModified : null,
      );
      if (response.notModified && previous != null) {
        await repository.finishCapture(expected);
        await tasks.updateStatus(
          id: task.id,
          status: PageSageTaskStatus.done,
          progress: 1,
          message: '网页未变化，本地完整性已核对',
        );
        return previous;
      }
      if (!const {
        'text/html',
        'application/xhtml+xml',
      }.contains(response.mime)) {
        throw const WebBookException('这个地址不是可提取正文的 HTML 网页');
      }
      final source = response.html;
      final url = response.url;
      final article = await Isolate.run(
        () => const ArticleExtractor().extract(source: source, pageUrl: url),
      );
      if (!article.isReadable) {
        throw const WebBookException('未能提取正文，网页可能需要登录、验证或 JavaScript');
      }
      token.throwIfCancelled();
      final images = <String, Uint8List>{};
      var total = 0;
      final imageTime = Stopwatch()..start();
      for (final image in article.images) {
        token.throwIfCancelled();
        if (total >= 100 * 1024 * 1024 ||
            imageTime.elapsed > const Duration(seconds: 60)) {
          break;
        }
        try {
          final result = await http.fetch(
            image.url,
            maxBytes: 20 * 1024 * 1024,
            token: token,
          );
          final size = readImageSize(result.bytes);
          if (!result.mime.startsWith('image/') ||
              size == null ||
              size.width * size.height > 40000000 ||
              total + result.bytes.length > 100 * 1024 * 1024) {
            continue;
          }
          images[image.localPath] = result.bytes;
          total += result.bytes.length;
        } on TaskCancelledException {
          rethrow;
        } on WebBookException {
          continue;
        }
      }
      token.throwIfCancelled();
      final snapshot = await store.write(
        chapter: expected,
        article: article,
        finalUrl: response.url,
        images: images,
        etag: response.etag,
        lastModified: response.lastModified,
      );
      candidate = snapshot;
      token.throwIfCancelled();
      if (previousReadable &&
          previousCurrentExtraction &&
          previous?.sourceRevision == snapshot.sourceRevision) {
        await repository.finishCapture(expected);
        await tasks.updateStatus(
          id: task.id,
          status: PageSageTaskStatus.done,
          progress: 1,
          message: '网页内容未变化',
        );
        return previous;
      }
      await repository.publish(expected, snapshot);
      published = true;
      var indexed = true;
      try {
        await onChanged(chapter.bookId);
      } on Object {
        indexed = false;
      }
      await tasks.updateStatus(
        id: task.id,
        status:
            indexed &&
                images.length == article.images.length &&
                article.warnings.isEmpty
            ? PageSageTaskStatus.done
            : PageSageTaskStatus.partial,
        progress: 1,
        message: [
          '网页正文已保存，可离线阅读',
          if (images.length < article.images.length)
            '${article.images.length - images.length} 张图片未保存，可重试刷新',
          if (article.warnings.isNotEmpty) '部分媒体或图片不支持离线显示',
          if (!indexed) '搜索索引需要重试',
        ].join('；'),
      );
      return snapshot;
    } on Object catch (error) {
      final message = error is WebBookException
          ? error.message
          : error is TaskCancelledException
          ? '已取消，本地旧版本仍可阅读'
          : '网页保存失败，本地旧版本仍可阅读';
      if (expected != null) {
        await repository.finishCapture(expected, error: message);
      }
      await tasks.updateStatus(
        id: task.id,
        status: error is TaskCancelledException
            ? PageSageTaskStatus.cancelled
            : PageSageTaskStatus.failed,
        progress: 1,
        message: message,
      );
      if (error is WebBookException || error is TaskCancelledException) rethrow;
      throw WebBookException(message);
    } finally {
      cancellation.complete(task.id);
      if (!published && candidate != null) await store.discard(candidate);
    }
  }

  Future<({int succeeded, int failed})> refreshBook(String bookId) async {
    final chapters = await repository.chapters(bookId);
    final task = await tasks.saveTask(
      type: PageSageTaskType.webCapture,
      status: PageSageTaskStatus.running,
      bookId: bookId,
      message: '正在刷新网络书，共 ${chapters.length} 章',
    );
    final token = cancellation.register(task.id);
    var succeeded = 0;
    var failed = 0;
    try {
      for (final chapter in chapters) {
        token.throwIfCancelled();
        try {
          await refresh(chapter, batchToken: token);
          succeeded++;
        } on TaskCancelledException {
          rethrow;
        } on Object {
          failed++;
        }
        await tasks.updateStatus(
          id: task.id,
          status: PageSageTaskStatus.running,
          progress: (succeeded + failed) / chapters.length,
          message:
              '已刷新 ${succeeded + failed}/${chapters.length} 章，$failed 章未完成',
        );
      }
      await tasks.updateStatus(
        id: task.id,
        status: failed == 0
            ? PageSageTaskStatus.done
            : PageSageTaskStatus.partial,
        progress: 1,
        message: '刷新结束：$succeeded 章成功，$failed 章未完成',
      );
      return (succeeded: succeeded, failed: failed);
    } on TaskCancelledException {
      await tasks.updateStatus(
        id: task.id,
        status: PageSageTaskStatus.cancelled,
        message: '刷新已取消，已完成 $succeeded 章；已有离线内容保留',
      );
      rethrow;
    } finally {
      cancellation.complete(task.id);
    }
  }

  Future<void> recover(String bookId) async {
    for (final task in await tasks.getTasks()) {
      if (task.type != PageSageTaskType.webCapture ||
          task.bookId != bookId ||
          task.status != PageSageTaskStatus.running ||
          cancellation.isLive(task.id) ||
          cancellation.isCancelled(task.id)) {
        continue;
      }
      final chapter = (await repository.chapters(
        bookId,
      )).where((entry) => entry.id == task.sourcePath).firstOrNull;
      if (chapter != null) {
        await repository.finishCapture(chapter, error: '上次获取已中断，可重试；已保存内容仍保留');
      }
      await tasks.updateStatus(
        id: task.id,
        status: PageSageTaskStatus.failed,
        message: '获取已中断，请在网络书中重试',
      );
    }
  }
}
