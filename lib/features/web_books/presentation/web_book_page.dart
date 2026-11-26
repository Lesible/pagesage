import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/web_books/web_book.dart';
import '../application/web_book_providers.dart';

Future<void> createWebBook(BuildContext context, WidgetRef ref) async {
  final title = await showDialog<String>(
    context: context,
    builder: (_) => const _TextDialog(
      title: '新建网络书',
      label: '书名',
      hint: '例如：我的技术阅读',
      action: '创建',
    ),
  );
  if (title == null) return;
  try {
    final book = await ref.read(webBookServiceProvider).create(title);
    if (context.mounted) context.push('/web-book/${book.id}');
  } on Object {
    if (context.mounted) _notice(context, '网络书创建失败，请重试');
  }
}

final class WebBookPage extends ConsumerStatefulWidget {
  const WebBookPage({required this.bookId, super.key});
  final String bookId;

  @override
  ConsumerState<WebBookPage> createState() => _WebBookPageState();
}

final class _WebBookPageState extends ConsumerState<WebBookPage> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(webBookServiceProvider).recover(widget.bookId));
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await action();
      if (mounted) setState(() => _message = result);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _message = error is WebBookException
              ? error.message
              : '操作未完成，请重试；已保存的网页仍可阅读',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() => _run(() async {
    final value = _url.text.trim();
    if (value.isEmpty) throw const WebBookException('请输入网页地址');
    await ref.read(webBookServiceProvider).add(widget.bookId, value);
    _url.clear();
    return '网页已保存，可离线阅读';
  });

  @override
  Widget build(BuildContext context) {
    final chapters = ref.watch(webChaptersProvider(widget.bookId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('网络书章节'),
        actions: [
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final result = await ref
                        .read(webBookServiceProvider)
                        .refreshBook(widget.bookId);
                    return '刷新完成：${result.succeeded} 章成功，${result.failed} 章未完成';
                  }),
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('刷新全部'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '把网页加入同一本书',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('添加后保存正文和支持的图片。离线时直接阅读已保存内容；需要更新时手动刷新。'),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _url,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      onSubmitted: (_) => _add(),
                      decoration: InputDecoration(
                        labelText: '网页地址',
                        hintText: 'https://example.com/article',
                        suffixIcon: IconButton(
                          tooltip: '添加并保存网页',
                          onPressed: _busy ? null : _add,
                          icon: const Icon(Icons.add),
                        ),
                      ),
                    ),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_message!, semanticsLabel: _message),
                      ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (_busy)
                      TextButton(
                        onPressed: () => context.push('/tasks'),
                        child: const Text('查看进度或取消'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: chapters.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => const Center(child: Text('章节读取失败，请重新打开')),
                  data: (items) => items.isEmpty
                      ? const Center(child: Text('还没有章节，先添加一个网页地址'))
                      : ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final chapter = items[index];
                            return ListTile(
                              leading: Icon(
                                chapter.snapshotId == null
                                    ? Icons.cloud_download_outlined
                                    : Icons.article_outlined,
                              ),
                              title: Text(
                                chapter.displayTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${chapter.lastError ?? (chapter.state == 'fetching'
                                        ? '正在保存…'
                                        : chapter.snapshotId == null
                                        ? '尚未保存'
                                        : '已保存，可离线阅读')}\n${chapter.url}',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: chapter.snapshotId == null
                                  ? null
                                  : () => _open(chapter),
                              trailing: PopupMenuButton<String>(
                                tooltip: '章节操作',
                                onSelected: (action) =>
                                    _action(action, chapter, items, index),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'source',
                                    child: Text('在浏览器中打开原网页'),
                                  ),
                                  if (chapter.snapshotId != null)
                                    const PopupMenuItem(
                                      value: 'details',
                                      child: Text('来源与离线保存情况'),
                                    ),
                                  if (!_busy) ...[
                                    const PopupMenuItem(
                                      value: 'refresh',
                                      child: Text('刷新这一章'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Text('修改章节名'),
                                    ),
                                    if (index > 0)
                                      const PopupMenuItem(
                                        value: 'up',
                                        child: Text('上移'),
                                      ),
                                    if (index < items.length - 1)
                                      const PopupMenuItem(
                                        value: 'down',
                                        child: Text('下移'),
                                      ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('移除章节'),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(WebChapter chapter) async {
    try {
      final snapshot = await ref
          .read(webBookRepositoryProvider)
          .snapshot(chapter.snapshotId!);
      if (snapshot == null) throw const WebBookException('本地版本不可用，请刷新章节');
      if (mounted) {
        context.push('/book/${widget.bookId}/reader', extra: snapshot.locator);
      }
    } on Object {
      if (mounted) _notice(context, '无法打开这个章节，请刷新后重试');
    }
  }

  Future<void> _action(
    String action,
    WebChapter chapter,
    List<WebChapter> items,
    int index,
  ) async {
    if (action == 'details') {
      try {
        final snapshot = await ref
            .read(webBookRepositoryProvider)
            .snapshot(chapter.snapshotId!);
        if (snapshot == null) throw const WebBookException('本地版本缺失');
        final notice = await ref
            .read(webSnapshotStoreProvider)
            .notice(snapshot);
        if (!mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapter.displayTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  const Text('原网页'),
                  SelectableText(snapshot.finalUrl),
                  const SizedBox(height: 16),
                  Text(
                    '保存时间：${DateTime.fromMillisecondsSinceEpoch(snapshot.createdAt).toLocal()}',
                  ),
                  if (chapter.checkedAt != null)
                    Text(
                      '最近检查：${DateTime.fromMillisecondsSinceEpoch(chapter.checkedAt!).toLocal()}',
                    ),
                  const SizedBox(height: 8),
                  Text(notice ?? '正文和支持的图片均已保存，可离线阅读'),
                  Text('当前版本占用：${(snapshot.byteSize / 1024).ceil()} KB'),
                  const SizedBox(height: 8),
                  const Text('刷新会保留历史版本，已有书签、笔记和批注仍指向原来的内容。'),
                ],
              ),
            ),
          ),
        );
      } on Object {
        if (mounted) _notice(context, '无法读取本地保存信息，请重新保存网页');
      }
      return;
    }
    if (action == 'source') {
      try {
        if (!await launchUrl(
          Uri.parse(chapter.url),
          mode: LaunchMode.externalApplication,
        )) {
          throw const WebBookException('无法打开浏览器');
        }
      } on Object {
        if (mounted) _notice(context, '无法打开浏览器');
      }
      return;
    }
    if (action == 'rename') {
      final title = await showDialog<String>(
        context: context,
        builder: (_) => _TextDialog(
          title: '修改章节名',
          label: '章节名',
          initial: chapter.displayTitle,
          action: '保存',
        ),
      );
      if (title == null || !mounted) return;
      return _run(() async {
        await ref.read(webBookRepositoryProvider).rename(chapter.id, title);
        await ref.read(webBookServiceProvider).onChanged(widget.bookId);
        return '章节名已保存';
      });
    }
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('移除章节？'),
          content: const Text('章节将从列表和正文搜索中移除。已有批注和笔记引用的历史版本仍保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    return _run(() async {
      final repository = ref.read(webBookRepositoryProvider);
      if (action == 'refresh') {
        await ref.read(webBookServiceProvider).refresh(chapter);
        return '网页已刷新；重新打开章节可阅读最新版本';
      }
      if (action == 'delete') {
        await repository.deleteChapter(chapter.id);
      } else if (action == 'up' || action == 'down') {
        final ids = items.map((entry) => entry.id).toList();
        final destination = action == 'up' ? index - 1 : index + 1;
        if (destination < 0 || destination >= ids.length) return '章节顺序未变化';
        ids.removeAt(index);
        ids.insert(destination, chapter.id);
        await repository.reorder(widget.bookId, ids);
      }
      await ref.read(webBookServiceProvider).onChanged(widget.bookId);
      return '章节列表已更新';
    });
  }
}

final class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.action,
    this.hint,
    this.initial = '',
  });
  final String title;
  final String label;
  final String action;
  final String? hint;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

final class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_controller.text.trim().isNotEmpty) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 200,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: Text(widget.action)),
    ],
  );
}

void _notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
