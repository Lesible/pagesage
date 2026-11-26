import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../domain/books/book.dart';
import '../../../domain/books/reading_position.dart';
import '../../../renderers/common/renderer_event.dart';
import 'reader_location_text.dart';
import 'reader_mobile_chrome.dart';
import 'reader_chrome.dart';

final class ReaderMobileOverlay extends StatelessWidget {
  const ReaderMobileOverlay({
    required this.book,
    required this.progress,
    required this.location,
    required this.visible,
    required this.bookmarked,
    required this.onToggle,
    required this.onReveal,
    required this.onBack,
    required this.onToc,
    required this.onMore,
    required this.onSearch,
    required this.onBookmark,
    this.onProgressTap,
    super.key,
  });

  final Book book;
  final ReadingProgressSnapshot? progress;
  final ValueListenable<RendererLocationChanged?> location;
  final bool visible;
  final bool bookmarked;
  final VoidCallback onToggle;
  final VoidCallback onReveal;
  final Future<void> Function() onBack;
  final VoidCallback onToc;
  final VoidCallback onMore;
  final VoidCallback onSearch;
  final VoidCallback onBookmark;
  final VoidCallback? onProgressTap;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        left: 72,
        right: 72,
        top: 0,
        bottom: 0,
        child: Center(
          child: SizedBox(
            height: 120,
            width: double.infinity,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onToggle,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
      Positioned(
        left: AppSpacing.x2,
        right: AppSpacing.x2,
        top: AppSpacing.x2,
        child: _MobileChromeTransition(
          visible: visible,
          offset: const Offset(0, -.35),
          child: SafeArea(
            bottom: false,
            child: ValueListenableBuilder<RendererLocationChanged?>(
              valueListenable: location,
              builder: (context, current, _) => MobileReaderTopBar(
                title: book.title,
                progress: current?.progress ?? progress?.progress,
                locationLabel: readerLocationText(
                  book: book,
                  locator: current?.locator ?? progress?.locator,
                  chapterTitle: current?.chapterTitle ?? progress?.chapterTitle,
                  pageNumber: current?.pageNumber,
                  totalPages: current?.totalPages,
                ),
                onBack: onBack,
                onToc: onToc,
                onMore: onMore,
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: AppSpacing.x2,
        right: AppSpacing.x2,
        bottom: AppSpacing.x2,
        child: _MobileChromeTransition(
          visible: visible,
          offset: const Offset(0, .35),
          child: SafeArea(
            top: false,
            child: ValueListenableBuilder<RendererLocationChanged?>(
              valueListenable: location,
              builder: (context, current, _) => MobileReaderBottomBar(
                book: book,
                locator: current?.locator ?? progress?.locator,
                progress: current?.progress ?? progress?.progress,
                chapterTitle: current?.chapterTitle ?? progress?.chapterTitle,
                pageNumber: current?.pageNumber,
                totalPages: current?.totalPages,
                bookmarked: bookmarked,
                onToc: onToc,
                onSearch: onSearch,
                onBookmark: onBookmark,
                onProgressTap: onProgressTap,
                onMore: onMore,
              ),
            ),
          ),
        ),
      ),
      if (!visible)
        Positioned(
          right: AppSpacing.x3,
          bottom: AppSpacing.x3,
          child: SafeArea(
            top: false,
            child: ReaderChromeRevealButton(onPressed: onReveal),
          ),
        ),
    ],
  );
}

final class _MobileChromeTransition extends StatelessWidget {
  const _MobileChromeTransition({
    required this.visible,
    required this.offset,
    required this.child,
  });
  final bool visible;
  final Offset offset;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: ExcludeFocus(
      excluding: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : offset,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: visible ? 1 : 0,
            child: child,
          ),
        ),
      ),
    ),
  );
}
