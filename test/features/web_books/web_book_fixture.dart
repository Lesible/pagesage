import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/drift_ai_conversation_repository.dart';
import 'package:pagesage/core/database/drift_annotation_repository.dart';
import 'package:pagesage/core/database/drift_book_repository.dart';
import 'package:pagesage/core/database/drift_bookmark_repository.dart';
import 'package:pagesage/core/database/drift_note_repository.dart';
import 'package:pagesage/core/database/drift_search_repository.dart';
import 'package:pagesage/core/database/drift_task_repository.dart';
import 'package:pagesage/core/database/drift_web_book_repository.dart';
import 'package:pagesage/core/files/app_paths.dart';
import 'package:pagesage/core/files/image_cache_store.dart';
import 'package:pagesage/core/search/search_indexer.dart';
import 'package:pagesage/core/tasks/task_cancellation.dart';
import 'package:pagesage/features/export/application/export_service.dart';
import 'package:pagesage/features/web_books/application/web_book_service.dart';
import 'package:pagesage/features/web_books/data/web_snapshot_store.dart';
import 'package:pagesage/renderers/web/web_document_loader.dart';

final class WebBookFixture {
  WebBookFixture._(this.root, this.paths, this.database);
  final Directory root;
  final AppPaths paths;
  AppDatabase database;
  HttpServer? server;
  int revision = 1;
  bool fail = false;
  bool slow = false;
  bool malformedImage = false;
  bool validators = false;
  int conditionalHits = 0;
  int hits = 0;
  final arrived = Completer<void>();
  final release = Completer<void>();
  final registry = TaskCancellationRegistry();

  static Future<WebBookFixture> create() async {
    final root = await Directory.systemTemp.createTemp('pagesage-web-book-');
    final paths = AppPaths(overrideRoot: root);
    final file = await paths.databaseFile();
    await file.parent.create(recursive: true);
    final fixture = WebBookFixture._(
      root,
      paths,
      AppDatabase.forTesting(NativeDatabase(file)),
    );
    await fixture.database.customSelect('SELECT 1').get();
    return fixture;
  }

  DriftWebBookRepository get repository => DriftWebBookRepository(database);
  WebSnapshotStore get store => WebSnapshotStore(paths);
  DriftTaskRepository get tasks => DriftTaskRepository(database.taskDao);
  DriftSearchRepository get search => DriftSearchRepository(database.searchDao);
  DriftBookRepository get books => DriftBookRepository(
    bookDao: database.bookDao,
    progressDao: database.progressDao,
    searchDao: database.searchDao,
  );
  SearchIndexer get indexer => SearchIndexer(
    searchRepository: search,
    bookRepository: books,
    webRepository: repository,
    webLoader: (snapshot) async {
      final directory = await store.directory(snapshot.bookId, snapshot.id);
      return WebDocumentLoader(snapshot, directory.path).load(directory.path);
    },
  );
  late final service = WebBookService(
    repository: repository,
    store: store,
    tasks: tasks,
    cancellation: registry,
    onChanged: (id) async {
      final book = await books.getBook(id);
      if (book != null) await indexer.indexBook(book);
    },
  );

  ExportService get exporter => ExportService(
    appPaths: paths,
    database: database,
    noteRepository: DriftNoteRepository(database.noteDao, search),
    bookmarkRepository: DriftBookmarkRepository(database.bookmarkDao, search),
    annotationRepository: DriftAnnotationRepository(database.annotationDao),
    aiConversationRepository: DriftAiConversationRepository(
      database.aiConversationDao,
      search,
    ),
    imageCacheStore: CachedImageStore(appPaths: paths),
    bookRepository: books,
  );

  Future<String> serve() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      hits++;
      if (slow && request.uri.path != '/image.png') {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
      }
      if (fail) {
        request.response.statusCode = 503;
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, '/one');
      } else if (request.uri.path == '/image.png') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(
          malformedImage
              ? [0x89, 0x50, 0x4e, 0x47]
              : base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6/GQAAAAASUVORK5CYII=',
                ),
        );
      } else {
        if (validators) {
          final etag = '"revision-$revision"';
          request.response.headers.set(HttpHeaders.etagHeader, etag);
          if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
            conditionalHits++;
            request.response.statusCode = 304;
            await request.response.close();
            return;
          }
        }
        request.response.headers.contentType = ContentType.html;
        request.response.write('''
<!doctype html><html><head><title>网页 ${request.uri.path}</title></head><body>
<nav>不应加入正文的导航菜单</nav><main><article>
<h1>离线网络书 ${request.uri.path}</h1><h2 id="intro">章节说明</h2>
<p>这是版本 $revision 的网络知识库内容，矩阵运算与离线阅读。${'正文段落包含足够的实际文字用于验证提取与中文搜索。' * 12}</p>
<img src="/image.png" alt="本地示意图">
<h2 id="code">代码与表格</h2><pre><code>final value = $revision;</code></pre>
<table><tr><th>名称</th><th>值</th></tr><tr><td>版本</td><td>$revision</td></tr></table>
<p><a href="/two">下一篇网页</a></p></article></main></body></html>
''');
      }
      await request.response.close();
    });
    return 'http://127.0.0.1:${server!.port}';
  }

  Future<void> offline() async {
    if (!release.isCompleted) release.complete();
    await server?.close(force: true);
    server = null;
  }

  Future<void> reopen() async {
    await database.close();
    database = AppDatabase.forTesting(
      NativeDatabase(await paths.databaseFile()),
    );
    await database.customSelect('SELECT 1').get();
  }

  Future<void> dispose() async {
    await offline();
    await database.close();
    await root.delete(recursive: true);
  }
}
