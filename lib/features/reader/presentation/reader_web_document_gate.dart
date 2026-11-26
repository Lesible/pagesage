import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/books/reading_position.dart';
import '../../web_books/application/web_reading_source.dart';
import '../application/web_reader_session.dart';

final class ReaderWebDocumentGate extends StatelessWidget {
  const ReaderWebDocumentGate({
    required this.session,
    required this.initialLocator,
    required this.onReload,
    required this.builder,
    super.key,
  });

  final WebReaderSession session;
  final ReadingLocator? initialLocator;
  final VoidCallback onReload;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => FutureBuilder<WebReadingSource?>(
    future: session.load(initialLocator),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError || snapshot.data == null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  snapshot.hasError ? '这个网页版本无法打开，请从章节列表选择' : '网络书还没有已保存的章节',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    await context.push('/web-book/${session.bookId}');
                    if (!context.mounted) return;
                    session.reload();
                    onReload();
                  },
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('添加或管理网页'),
                ),
              ],
            ),
          ),
        );
      }
      final notice = snapshot.data?.notice;
      if (notice == null) return builder(context);
      return Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline, size: 18),
              title: Text('已保存正文 · $notice'),
              trailing: TextButton(
                onPressed: () => context.push('/web-book/${session.bookId}'),
                child: const Text('管理'),
              ),
            ),
          ),
          Expanded(child: builder(context)),
        ],
      );
    },
  );
}
