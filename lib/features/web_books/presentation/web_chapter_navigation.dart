import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/books/reading_position.dart';
import '../../../domain/web_books/web_book.dart';
import '../../../domain/web_books/web_chapter_group.dart';
import '../application/web_book_providers.dart';

final class WebChapterNavigation extends ConsumerStatefulWidget {
  const WebChapterNavigation({
    required this.bookId,
    required this.activeChapterId,
    required this.onSelected,
    this.filter = '',
    super.key,
  });
  final String bookId;
  final String? activeChapterId;
  final ValueChanged<ReadingLocator> onSelected;
  final String filter;

  @override
  ConsumerState<WebChapterNavigation> createState() =>
      _WebChapterNavigationState();
}

final class _WebChapterNavigationState
    extends ConsumerState<WebChapterNavigation> {
  final Set<String> _knownGroups = {};
  final Set<String> _expanded = {};
  String? _lastActive;
  int _selectionGeneration = 0;

  @override
  void didUpdateWidget(covariant WebChapterNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      _knownGroups.clear();
      _expanded.clear();
      _lastActive = null;
      _selectionGeneration++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.playlist_add, size: 20),
          title: const Text('添加或管理网页'),
          onTap: () => context.push('/web-book/${widget.bookId}'),
        ),
        const Divider(height: 1),
        Expanded(
          child: ref
              .watch(webChaptersProvider(widget.bookId))
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => const Center(child: Text('无法读取章节')),
                data: (chapters) => _tree(context, chapters),
              ),
        ),
      ],
    );
  }

  Widget _tree(BuildContext context, List<WebChapter> chapters) {
    final groups = groupWebChapters(chapters, filter: widget.filter);
    for (final group in groups) {
      if (_knownGroups.add(group.key)) _expanded.add(group.key);
      if (_lastActive != widget.activeChapterId &&
          group.chapters.any(
            (chapter) => chapter.id == widget.activeChapterId,
          )) {
        _expanded.add(group.key);
      }
    }
    _lastActive = widget.activeChapterId;
    if (groups.isEmpty) return const Center(child: Text('没有匹配的网页'));
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        for (final group in groups) ...[
          ListTile(
            key: ValueKey('web-source-${group.key}'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: Icon(
              _expanded.contains(group.key) || widget.filter.isNotEmpty
                  ? Icons.keyboard_arrow_down
                  : Icons.chevron_right,
              size: 18,
            ),
            minLeadingWidth: 18,
            title: Text(
              group.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            trailing: Text(
              '${group.chapters.length}',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            onTap: () => setState(() {
              if (!_expanded.remove(group.key)) _expanded.add(group.key);
            }),
          ),
          if (_expanded.contains(group.key) || widget.filter.isNotEmpty)
            for (final chapter in group.chapters)
              Padding(
                padding: const EdgeInsets.only(left: 19),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  child: ListTile(
                    dense: true,
                    selected: chapter.id == widget.activeChapterId,
                    contentPadding: const EdgeInsets.only(left: 12, right: 8),
                    minLeadingWidth: 16,
                    leading: Icon(
                      chapter.id == widget.activeChapterId
                          ? Icons.menu_book_outlined
                          : Icons.article_outlined,
                      size: 16,
                    ),
                    title: Text(
                      chapter.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: chapter.snapshotId == null
                        ? const Text('尚未保存，请在管理中重试')
                        : null,
                    onTap: chapter.snapshotId == null
                        ? null
                        : () => _select(chapter),
                  ),
                ),
              ),
        ],
      ],
    );
  }

  Future<void> _select(WebChapter chapter) async {
    final generation = ++_selectionGeneration;
    final bookId = widget.bookId;
    try {
      final snapshot = await ref
          .read(webBookRepositoryProvider)
          .snapshot(chapter.snapshotId!);
      if (snapshot == null) throw const WebBookException('本地版本不可用');
      if (mounted &&
          generation == _selectionGeneration &&
          bookId == widget.bookId) {
        widget.onSelected(snapshot.locator);
      }
    } on Object {
      if (mounted &&
          generation == _selectionGeneration &&
          bookId == widget.bookId) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开章节，请重新保存网页')));
      }
    }
  }
}
