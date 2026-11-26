import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pagesage/renderers/epub/epub_chapter_parser.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';

import 'article_extractor.dart';
import 'native_html_parser.dart';

EpubDocument toNativeDocument(
  ArticleExtraction article, {
  Map<String, Uint8List> imageBytes = const {},
}) {
  if (!article.isReadable) {
    throw StateError('不能装载未通过抽取的网页');
  }
  return NativeHtmlParser(imageBytes: imageBytes).parse(article);
}

EpubDocument toLegacyNativeDocument(
  ArticleExtraction article, {
  Map<String, Uint8List> imageBytes = const {},
}) {
  if (!article.isReadable) {
    throw StateError('不能装载未通过抽取的网页');
  }
  final entries = <String, ArchiveFile>{
    for (final image in article.images)
      if (imageBytes[image.localPath] case final Uint8List bytes)
        image.localPath: ArchiveFile(image.localPath, bytes.length, bytes),
  };
  final parsed = EpubChapterParser(
    entries: entries,
  ).parse(xhtml: article.xhtml, href: 'article.xhtml');
  final headings = parsed.blocks.whereType<EpubTextBlock>().where(
    (block) => block.type == EpubBlockType.heading,
  );
  return EpubDocument(
    chapters: [
      EpubChapter(
        index: 0,
        href: 'article.xhtml',
        title: article.title,
        text: parsed.text,
        blocks: parsed.blocks,
        anchors: parsed.anchors,
      ),
    ],
    toc: [
      for (final heading in headings)
        EpubTocItem(
          title: heading.text,
          href: 'article.xhtml',
          chapterIndex: 0,
          chapterOffset: heading.startOffset,
        ),
    ],
  );
}
