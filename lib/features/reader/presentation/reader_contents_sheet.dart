import 'package:flutter/material.dart';

import '../../../domain/books/book.dart';
import '../../../domain/books/reading_position.dart';
import '../../../renderers/common/book_document_loader.dart';
import '../../../renderers/epub/epub_document.dart';
import '../../../renderers/markdown/markdown_folder.dart';
import '../../web_books/presentation/web_chapter_navigation.dart';
import 'reader_epub_toc_sheet.dart';
import 'reader_chrome.dart';

Future<ReadingLocator?> showReaderContentsSheet({
  required BuildContext context,
  required Book book,
  required BookDocumentLoader loader,
  required String documentPath,
  required ReadingLocator? currentLocator,
  MarkdownFolderManifest? folderManifest,
  String? activeFolderFile,
  ValueChanged<MarkdownFolderFile>? onFolderFileSelected,
}) async {
  final document = folderManifest == null
      ? await loader.load(documentPath)
      : null;
  if (!context.mounted) return null;
  return showModalBottomSheet<ReadingLocator>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      void select(ReadingLocator locator) =>
          Navigator.pop(sheetContext, locator);
      final outline = EpubTocSheet(
        document: document,
        folderManifest: folderManifest,
        activeFolderFile: activeFolderFile,
        onFolderFileSelected: onFolderFileSelected,
        currentChapterIndex: currentLocator?.chapterIndex,
        currentChapterOffset: currentLocator?.chapterOffset ?? 0,
        onFolderLocatorSelected: select,
        onSelected: document == null
            ? null
            : (item) => select(_outlineLocator(book, document, item)),
      );
      return ReaderBottomSheetFrame(
        child: book.format != BookFormat.web
            ? outline
            : DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: '章节'),
                        Tab(text: '本页大纲'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          WebChapterNavigation(
                            bookId: book.id,
                            activeChapterId:
                                document?.sourceLocator?.webChapterId,
                            onSelected: select,
                          ),
                          outline,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      );
    },
  );
}

ReadingLocator _outlineLocator(
  Book book,
  EpubDocument document,
  EpubTocItem item,
) {
  final chapterIndex = (item.chapterIndex ?? 0).clamp(
    0,
    document.chapters.length - 1,
  );
  final chapter = document.chapters[chapterIndex];
  final progress = document.progressForChapter(
    chapterIndex: chapter.index,
    chapterOffset: item.chapterOffset ?? 0,
  );
  final web = document.sourceLocator;
  if (web != null) {
    return web.withWebPosition(
      chapterOffset: item.chapterOffset ?? 0,
      progress: progress,
    );
  }
  return book.format == BookFormat.markdown
      ? ReadingLocator.markdown(
          href: item.href,
          chapterIndex: chapter.index,
          chapterOffset: item.chapterOffset,
          progress: progress,
        )
      : ReadingLocator.epub(
          href: item.href,
          chapterIndex: chapter.index,
          chapterOffset: item.chapterOffset,
          progress: progress,
        );
}
