import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/web_books/web_book.dart';
import '../../features/web_books/data/article_extractor.dart';
import '../common/book_document_loader.dart';
import '../epub/epub_document.dart';
import 'native_html_parser.dart';

final class WebDocumentLoader implements BookDocumentLoader {
  const WebDocumentLoader(this.snapshot, this.snapshotPath);
  final WebSnapshot snapshot;
  final String snapshotPath;

  @override
  Future<EpubDocument> load(String filePath) => Isolate.run(() async {
    final manifestFile = File(p.join(snapshotPath, 'manifest.json'));
    final manifestBytes = await manifestFile.readAsBytes();
    if (sha256.convert(manifestBytes).toString() != snapshot.manifestHash) {
      throw const WebBookException('本地网页清单受损，请刷新当前章节');
    }
    final manifest = jsonDecode(utf8.decode(manifestBytes));
    if (manifest is! Map<String, Object?> ||
        manifest['version'] != 1 ||
        manifest['images'] is! Map) {
      throw const WebBookException('本地网页版本不受支持');
    }
    if (manifest['sourceRevision'] != snapshot.sourceRevision ||
        manifest['textRevision'] != snapshot.textRevision ||
        manifest['finalUrl'] != snapshot.finalUrl) {
      throw const WebBookException('本地网页来源版本不一致，请重新保存');
    }
    final xhtml = await File(
      p.join(snapshotPath, 'article.xhtml'),
    ).readAsString();
    if (sha256.convert(utf8.encode(xhtml)).toString() !=
        manifest['articleHash']) {
      throw const WebBookException('本地网页正文受损，请刷新当前章节');
    }
    if (sha256
            .convert(utf8.encode(jsonEncode([1, xhtml, manifest['images']])))
            .toString() !=
        snapshot.sourceRevision) {
      throw const WebBookException('本地网页内容版本校验失败');
    }
    final images = <String, Uint8List>{};
    for (final entry in (manifest['images'] as Map).entries) {
      final path = entry.key.toString();
      if (!RegExp(r'^resources/[a-f0-9]{64}$').hasMatch(path)) {
        throw const WebBookException('本地资源路径无效');
      }
      final bytes = await File(p.join(snapshotPath, path)).readAsBytes();
      if (sha256.convert(bytes).toString() != entry.value) {
        throw const WebBookException('本地图片受损，请刷新章节');
      }
      images[path] = bytes;
    }
    final article = ArticleExtraction(
      title: snapshot.title,
      xhtml: xhtml,
      text: '',
      images: const [],
      warnings: const {},
    );
    final document = NativeHtmlParser(imageBytes: images).parse(article);
    if (sha256
            .convert(
              utf8.encode('web-native-v1:${document.chapters.single.text}'),
            )
            .toString() !=
        snapshot.textRevision) {
      throw const WebBookException('本地网页文本版本校验失败');
    }
    final href = snapshot.locator.href!;
    EpubTocItem outline(EpubTocItem item) => EpubTocItem(
      title: item.title,
      href: href,
      chapterIndex: item.chapterIndex,
      chapterOffset: item.chapterOffset,
      fragment: item.fragment,
      children: item.children.map(outline).toList(),
    );
    return EpubDocument(
      sourceLocator: snapshot.locator,
      chapters: [
        for (final chapter in document.chapters)
          EpubChapter(
            index: chapter.index,
            href: href,
            title: chapter.title,
            text: chapter.text,
            blocks: chapter.blocks,
            anchors: chapter.anchors,
          ),
      ],
      toc: document.toc.map(outline).toList(),
    );
  });
}
