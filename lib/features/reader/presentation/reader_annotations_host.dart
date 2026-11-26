import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/annotations/annotation.dart';
import '../../../domain/books/book.dart';
import '../../../domain/books/reader_settings.dart';
import '../../../domain/books/reading_position.dart';
import '../../../renderers/common/renderer_event.dart';
import '../../../renderers/common/book_document_loader.dart';
import '../../../renderers/pdf/pdf_canvas_view.dart' show PdfZoomChanged;
import '../application/reader_notebook_providers.dart';
import 'reader_renderer_host.dart';

/// Leaf host: only this subtree rebuilds when annotations change.
final class ReaderAnnotationsHost extends ConsumerWidget {
  const ReaderAnnotationsHost({
    required this.bookId,
    required this.book,
    required this.progress,
    this.documentPath,
    this.documentLoader,
    this.webLocator,
    this.folderRelativePath,
    required this.settings,
    required this.version,
    required this.jumpToken,
    required this.searchQuery,
    required this.focusLocator,
    required this.clearSearchHighlightsVersion,
    required this.clearSelectionVersion,
    required this.onEvent,
    required this.ocrOverlayToken,
    required this.ocrOverlayPage,
    required this.ocrOverlayBlocks,
    this.onZoomChanged,
    this.imageDragMode = false,
    this.onImageAreaSelected,
    this.translationRequest = 0,
    this.onTranslationVisibilityChanged,
    super.key,
  });

  final String bookId;
  final Book book;
  final ReadingProgressSnapshot? progress;
  final String? documentPath;
  final BookDocumentLoader? documentLoader;
  final ReadingLocator? webLocator;
  final String? folderRelativePath;
  final ReaderSettings settings;
  final int version;
  final int jumpToken;
  final String? searchQuery;
  final ReadingLocator? focusLocator;
  final int clearSearchHighlightsVersion;
  final int clearSelectionVersion;
  final ValueChanged<RendererEvent> onEvent;
  final int ocrOverlayToken;
  final int? ocrOverlayPage;
  final List<Map<String, Object?>> ocrOverlayBlocks;
  final PdfZoomChanged? onZoomChanged;
  final bool imageDragMode;
  final ValueChanged<RendererImageAreaSelected>? onImageAreaSelected;
  final int translationRequest;
  final ValueChanged<bool>? onTranslationVisibilityChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotations =
        ref.watch(annotationsByBookProvider(bookId)).value ??
        const <Annotation>[];
    return ref.watch(readerRendererHostProvider)(
      ReaderRendererHostConfig(
        book: book,
        progress: progress,
        documentPath: documentPath,
        documentLoader: documentLoader,
        webLocator: webLocator,
        folderRelativePath: folderRelativePath,
        settings: settings,
        annotations: annotations,
        version: version,
        jumpToken: jumpToken,
        searchQuery: searchQuery,
        focusLocator: focusLocator,
        clearSearchHighlightsVersion: clearSearchHighlightsVersion,
        clearSelectionVersion: clearSelectionVersion,
        onEvent: onEvent,
        ocrOverlayToken: ocrOverlayToken,
        ocrOverlayPage: ocrOverlayPage,
        ocrOverlayBlocks: ocrOverlayBlocks,
        onZoomChanged: onZoomChanged,
        imageDragMode: imageDragMode,
        onImageAreaSelected: onImageAreaSelected,
        translationRequest: translationRequest,
        onTranslationVisibilityChanged: onTranslationVisibilityChanged,
      ),
    );
  }
}
