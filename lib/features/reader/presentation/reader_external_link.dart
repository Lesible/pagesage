import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/books/book.dart';
import '../../../domain/books/reading_position.dart';
import '../../../domain/web_books/web_book.dart';
import '../../web_books/application/web_book_providers.dart';
import '../../web_books/application/web_reading_source.dart';
import '../../web_books/data/web_http_client.dart';

Future<ReadingLocator?> openReaderExternalLink({
  required BuildContext context,
  required WidgetRef ref,
  required Book? book,
  required String url,
}) async {
  try {
    final uri = Uri.parse(url);
    final isWebBook = book?.format == BookFormat.web;
    if (isWebBook) {
      final normalized = webUrl(url).toString();
      final repository = ref.read(webBookRepositoryProvider);
      final chapters = await repository.chapters(book!.id);
      final saved = chapters
          .where(
            (chapter) =>
                chapter.url == normalized && chapter.snapshotId != null,
          )
          .firstOrNull;
      if (saved != null) {
        final snapshot = await repository.snapshot(saved.snapshotId!);
        if (snapshot != null) {
          final source = await WebReadingSource.resolve(
            bookId: book.id,
            repository: repository,
            store: ref.read(webSnapshotStoreProvider),
            locator: snapshot.locator,
          );
          if (source != null) {
            final document = await source.loader.load(source.path);
            return snapshot.locator.withWebPosition(
              chapterOffset:
                  document.chapters.single.anchors[uri.fragment] ?? 0,
            );
          }
        }
      }
    }
    if (!context.mounted) return null;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isWebBook ? '网页链接' : '打开外部链接'),
        content: SelectableText(
          url,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (isWebBook)
            TextButton(
              onPressed: () => Navigator.pop(context, 'add'),
              child: const Text('添加为章节'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'open'),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return null;
    if (action == 'add' && book != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在保存网页，可在任务中心查看进度或取消'),
          duration: Duration(seconds: 3),
        ),
      );
      await ref.read(webBookServiceProvider).add(book.id, url);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('网页已加入章节列表')));
      }
    } else if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const WebBookException('无法打开链接，请检查系统浏览器设置');
    }
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is WebBookException ? error.message : '无法打开或保存链接，请重试',
          ),
        ),
      );
    }
  }
  return null;
}
