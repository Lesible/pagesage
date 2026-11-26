import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_select_field.dart';
import '../../../core/database/database_providers.dart'
    show translationSettingsRepositoryProvider;
import '../../../domain/books/book.dart';
import '../../../domain/books/reading_position.dart';
import '../../../domain/translation/reading_translation.dart';
import '../../../domain/translation/translation_models.dart';
import '../../../renderers/common/book_document_loader.dart';
import '../../../renderers/common/renderer_event.dart';
import '../../settings/presentation/settings_page.dart';
import '../application/reading_translation_controller.dart';
import '../application/translation_providers.dart';

final class ReaderTranslationWorkspace extends ConsumerStatefulWidget {
  const ReaderTranslationWorkspace({
    required this.book,
    required this.request,
    required this.initialLocator,
    required this.onEvent,
    required this.builder,
    this.documentPath,
    this.documentLoader,
    this.sourceLocator,
    this.onVisibilityChanged,
    super.key,
  });
  final Book book;
  final int request;
  final ReadingLocator? initialLocator;
  final ReadingLocator? sourceLocator;
  final String? documentPath;
  final BookDocumentLoader? documentLoader;
  final ValueChanged<RendererEvent> onEvent;
  final ValueChanged<bool>? onVisibilityChanged;
  final Widget Function(
    ValueChanged<RendererEvent> onEvent,
    ReflowTranslation? translation,
  )
  builder;

  @override
  ConsumerState<ReaderTranslationWorkspace> createState() =>
      _ReaderTranslationWorkspaceState();
}

final class _ReaderTranslationWorkspaceState
    extends ConsumerState<ReaderTranslationWorkspace> {
  ReadingTranslationController? _controller;
  ReadingLocator? _locator;
  ReadingTranslationSource? _source;
  bool _open = false;
  bool _loadingSource = false;
  String? _sourceError;
  String? _profileId;
  String? _language;
  String? _savedFingerprint;
  int _sourceGeneration = 0;
  int _configurationGeneration = 0;
  TranslationDisplayMode _mode = TranslationDisplayMode.bilingual;

  @override
  void initState() {
    super.initState();
    _locator = widget.initialLocator;
  }

  @override
  void didUpdateWidget(covariant ReaderTranslationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.book.id != oldWidget.book.id ||
        widget.documentPath != oldWidget.documentPath ||
        widget.sourceLocator?.snapshotId !=
            oldWidget.sourceLocator?.snapshotId) {
      _locator = widget.initialLocator;
      if (_open) unawaited(_loadSource());
    }
    if (widget.request != oldWidget.request) {
      _open = !_open;
      if (_open) {
        _controller ??= ReadingTranslationController(
          repository: ref.read(readingTranslationRepositoryProvider),
          service: ref.read(translationServiceProvider),
        )..addListener(_changed);
        unawaited(_loadSource());
      } else {
        _sourceGeneration++;
        _controller?.cancel(notify: false);
      }
      _reportVisibility();
    }
  }

  void _reportVisibility() {
    if (widget.onVisibilityChanged == null) return;
    final open = _open;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && open == _open) widget.onVisibilityChanged?.call(open);
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onEvent(RendererEvent event) {
    if (event is RendererLocationChanged) {
      final previous = _locator?.page;
      _locator = event.locator;
      if (_open &&
          widget.book.format == BookFormat.pdf &&
          previous != _locator?.page) {
        unawaited(_loadSource());
      }
    }
    widget.onEvent(event);
  }

  Future<void> _loadSource() async {
    final generation = ++_sourceGeneration;
    _configurationGeneration++;
    _controller?.cancel(notify: false);
    _source = null;
    _sourceError = null;
    _loadingSource = true;
    _changed();
    try {
      final source = await ref
          .read(readingTranslationSourceLoaderProvider)
          .load(
            book: widget.book,
            locator: _locator,
            documentPath: widget.documentPath,
            documentLoader: widget.documentLoader,
            isCurrent: () =>
                mounted && _open && generation == _sourceGeneration,
          );
      if (!mounted || generation != _sourceGeneration || !_open) return;
      _source = source;
      final settings = await ref
          .read(translationSettingsRepositoryProvider)
          .getSettings();
      if (!mounted || generation != _sourceGeneration || !_open) return;
      _profileId ??=
          settings.defaultProfileId ?? settings.profiles.firstOrNull?.id;
      await _configure();
    } on TranslationException catch (failure) {
      if (mounted && generation == _sourceGeneration) {
        _sourceError = failure.message;
      }
    } on Object {
      if (mounted && generation == _sourceGeneration) {
        _sourceError = '无法读取本页翻译来源，请重试';
      }
    } finally {
      if (mounted && generation == _sourceGeneration) {
        setState(() => _loadingSource = false);
      }
    }
  }

  Future<void> _configure() async {
    final source = _source;
    if (source == null) return;
    final generation = ++_configurationGeneration;
    await _controller?.open(
      source,
      profileId: _savedFingerprint == null ? _profileId : null,
      language: _language,
      savedFingerprint: _savedFingerprint,
    );
    if (mounted &&
        _open &&
        generation == _configurationGeneration &&
        identical(source, _source) &&
        _controller?.plan == null &&
        _controller?.selectedFingerprint != null) {
      setState(() {
        _savedFingerprint = _controller!.selectedFingerprint;
        _language = _controller!.targetLanguage;
      });
    }
  }

  @override
  void dispose() {
    _sourceGeneration++;
    _configurationGeneration++;
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isPdf = widget.book.format == BookFormat.pdf;
    final translation =
        _open && !isPdf && _mode != TranslationDisplayMode.original
        ? ReflowTranslation(
            mode: _mode,
            texts: _source == null
                ? const {}
                : Map.unmodifiable(controller?.translations ?? const {}),
          )
        : null;
    final original = widget.builder(_onEvent, translation);
    final settings = _open
        ? ref.watch(translationSettingsProvider)
        : AsyncData(TranslationSettings());
    return Column(
      children: [
        if (_open && controller != null)
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: _header(context, controller, settings),
          ),
        if (_open) const Divider(height: 1),
        Expanded(
          key: const ValueKey('reader-translation-content'),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compare =
                  _open &&
                  isPdf &&
                  _mode != TranslationDisplayMode.original &&
                  controller != null;
              final onlyTranslation =
                  _open && _mode == TranslationDisplayMode.translated;
              final wide = constraints.maxWidth >= 720;
              final paneWidth = onlyTranslation
                  ? constraints.maxWidth
                  : constraints.maxWidth * .46;
              final paneHeight = onlyTranslation
                  ? constraints.maxHeight
                  : constraints.maxHeight * .5;
              return Stack(
                children: [
                  Positioned.fill(
                    right: compare && wide && !onlyTranslation ? paneWidth : 0,
                    bottom: compare && !wide && !onlyTranslation
                        ? paneHeight
                        : 0,
                    child: Offstage(
                      offstage: isPdf && onlyTranslation,
                      child: original,
                    ),
                  ),
                  if (compare)
                    Positioned(
                      right: 0,
                      top: wide || onlyTranslation
                          ? 0
                          : constraints.maxHeight - paneHeight,
                      bottom: 0,
                      width: wide ? paneWidth : constraints.maxWidth,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                          child: _pdfTranslations(controller),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    ReadingTranslationController controller,
    AsyncValue<TranslationSettings> settings,
  ) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final maximumFieldWidth = MediaQuery.sizeOf(context).width - 24;
    final profiles = settings.value?.profiles ?? const <TranslationProfile>[];
    final variants = <String, SavedReadingTranslation>{};
    for (final saved in controller.saved) {
      if (saved.fingerprint != controller.plan?.fingerprint) {
        variants.putIfAbsent(saved.fingerprint, () => saved);
      }
    }
    final selected = _savedFingerprint != null
        ? 'saved:$_savedFingerprint'
        : profiles.any((profile) => profile.id == _profileId)
        ? 'profile:$_profileId'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.translate, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _source?.label ??
                      (widget.book.format == BookFormat.pdf
                          ? '第 ${_locator?.page ?? 1} 页'
                          : '当前网页'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              IconButton(
                tooltip: '翻译设置',
                icon: const Icon(Icons.tune, size: 19),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(
                        initialTranslation: true,
                        returnLabel: '返回阅读',
                      ),
                    ),
                  );
                  if (mounted && _open) unawaited(_loadSource());
                },
              ),
              IconButton(
                tooltip: '关闭对照翻译',
                icon: const Icon(Icons.close, size: 19),
                onPressed: () {
                  setState(() {
                    _open = false;
                    _sourceGeneration++;
                    controller.cancel(notify: false);
                  });
                  _reportVisibility();
                },
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: (210 * textScale).clamp(120, maximumFieldWidth),
                child: AppSelectField<String>(
                  compact: true,
                  label: '翻译服务',
                  value: selected,
                  hint: profiles.isEmpty && variants.isEmpty
                      ? '请先配置翻译服务'
                      : '选择服务或已保存译文',
                  loading: settings.isLoading,
                  options: [
                    for (final profile in profiles)
                      AppSelectOption(
                        value: 'profile:${profile.id}',
                        label: profile.name,
                        description: profile.provider.label,
                      ),
                    for (final saved in variants.values)
                      AppSelectOption(
                        value: 'saved:${saved.fingerprint}',
                        label: '已保存 · ${saved.profileLabel}',
                        description:
                            '${translationLanguages[saved.targetLanguage] ?? saved.targetLanguage} · 离线可读',
                      ),
                  ],
                  onChanged: _loadingSource
                      ? null
                      : (value) {
                          setState(() {
                            if (value.startsWith('saved:')) {
                              _savedFingerprint = value.substring(6);
                              _language =
                                  variants[_savedFingerprint]?.targetLanguage;
                            } else {
                              _profileId = value.substring(8);
                              _savedFingerprint = null;
                            }
                          });
                          unawaited(_configure());
                        },
                ),
              ),
              SizedBox(
                width: (120 * textScale).clamp(120, maximumFieldWidth),
                child: AppSelectField<String>(
                  compact: true,
                  label: '目标语言',
                  value: _language ?? controller.targetLanguage,
                  options: [
                    for (final language in translationLanguages.entries)
                      if (language.key != 'auto')
                        AppSelectOption(
                          value: language.key,
                          label: language.value,
                        ),
                  ],
                  onChanged: _loadingSource
                      ? null
                      : (value) {
                          setState(() {
                            _language = value;
                            _savedFingerprint = null;
                          });
                          unawaited(_configure());
                        },
                ),
              ),
              SizedBox(
                width: (120 * textScale).clamp(120, maximumFieldWidth),
                child: AppSelectField<TranslationDisplayMode>(
                  compact: true,
                  label: '阅读方式',
                  value: _mode,
                  options: const [
                    AppSelectOption(
                      value: TranslationDisplayMode.original,
                      label: '仅原文',
                    ),
                    AppSelectOption(
                      value: TranslationDisplayMode.bilingual,
                      label: '原译对照',
                    ),
                    AppSelectOption(
                      value: TranslationDisplayMode.translated,
                      label: '仅译文',
                    ),
                  ],
                  onChanged: (value) => setState(() => _mode = value),
                ),
              ),
              if (controller.running)
                TextButton.icon(
                  onPressed: controller.cancel,
                  icon: const Icon(Icons.stop, size: 17),
                  label: const Text('取消'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed:
                      !_loadingSource &&
                          controller.canTranslate &&
                          (controller.completed <
                                  (_source?.units.length ?? 0) ||
                              controller.unsavedCount > 0)
                      ? controller.translateMissing
                      : null,
                  icon: const Icon(Icons.translate, size: 17),
                  label: Text(
                    controller.error != null
                        ? '重试未完成'
                        : widget.book.format == BookFormat.pdf
                        ? '翻译本页'
                        : '翻译当前网页',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (_loadingSource || controller.loading)
            const LinearProgressIndicator(minHeight: 2)
          else
            Text(
              _sourceError ??
                  controller.error ??
                  (settings.hasError
                      ? '无法读取翻译设置，请打开翻译设置重试'
                      : '${_source?.units.length ?? 0} 段 · 约 ${_source?.characterCount ?? 0} 字'
                            ' · 已完成 ${controller.completed} 段'
                            ' · 已保存 ${controller.savedPieceCount} 个片段'
                            '${controller.unsavedCount > 0 ? ' · ${controller.unsavedCount} 个片段尚未保存' : ''}'
                            '${controller.running
                                ? ' · 正在翻译'
                                : controller.cancelled
                                ? ' · 已取消'
                                : ''}'
                            ' · ${widget.book.format == BookFormat.pdf ? '按本页文本顺序对照' : '代码、公式和表格保留原文'}'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    _sourceError != null ||
                        controller.error != null ||
                        settings.hasError
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (_sourceError != null)
            TextButton(onPressed: _loadSource, child: const Text('重新读取本页')),
          if (controller.error != null &&
              !controller.canTranslate &&
              !_loadingSource &&
              !controller.loading)
            TextButton(onPressed: _configure, child: const Text('重新读取译文')),
        ],
      ),
    );
  }

  Widget _pdfTranslations(ReadingTranslationController controller) {
    if (_loadingSource) return const Center(child: CircularProgressIndicator());
    final source = _source;
    if (source == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_sourceError ?? '暂无可用来源'),
        ),
      );
    }
    return SelectionArea(
      child: ListView(
        key: ValueKey(source.key),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${source.label} · 译文',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '按本页文本顺序显示，未重建 PDF 版式；无可靠框时不做精确段落定位。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          for (final unit in source.units)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                controller.translations[unit.id] ?? '此段尚未翻译',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(height: 1.65),
              ),
            ),
        ],
      ),
    );
  }
}
