import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/features/reader/presentation/reader_chrome.dart';
import 'package:pagesage/features/reader/presentation/reader_desktop_toolbar.dart';
import 'package:pagesage/features/reader/presentation/reader_pdf_toolbar.dart';
import 'package:pagesage/features/reader/presentation/reader_mobile_chrome.dart';

import '../../support/reader_workbench_capture.dart';

void main() {
  _ReaderChromeCaptureBinding();
  setUpAll(() async {
    if (captureWorkbench) {
      await loadWorkbenchCaptureFonts();
    }
  });

  Future<void> pumpToolbar(
    WidgetTester tester, {
    double width = 1440,
    double textScale = 1,
    bool dark = false,
    VoidCallback? onAction,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final action = onAction ?? () {};
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      MaterialApp(
        theme: captureWorkbench
            ? theme.copyWith(
                appBarTheme: theme.appBarTheme.copyWith(
                  titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                    fontFamily: 'Segoe UI',
                  ),
                ),
              )
            : theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(key: workbenchCaptureKey, child: child!),
        ),
        home: Scaffold(
          appBar: ReaderDesktopToolbar(
            title: '一本包含很长书名的阅读器工具栏布局验证样本 / Markdown、EPUB 与 PDF',
            tocOpen: true,
            activeContextTab: ReaderContextTab.notebook,
            bookmarked: true,
            onBack: action,
            onToc: action,
            onSearch: action,
            onBookmark: action,
            onNotebook: action,
            onAi: action,
            onSettings: action,
            onMore: (_) => action(),
            moreItems: (_) => const [
              PopupMenuItem(
                value: ReaderMoreAction.quickTheme,
                child: Text('阅读主题与界面颜色'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(Scaffold))).width,
      width,
    );
  }

  testWidgets(
    'mobile PDF more actions remain reachable after adding comparison on a short screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var translated = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileReaderMoreSheet(
              book: const Book(
                id: 'book',
                title: 'PDF 书籍',
                format: BookFormat.pdf,
                libraryFilePath: '/fixture.pdf',
                fileHash: 'file',
                fileSize: 1,
                createdAt: 1,
                updatedAt: 1,
              ),
              settings: const ReaderSettings(),
              bookmarked: false,
              searchAvailable: false,
              textLayerAvailable: false,
              onSearch: () {},
              onBookmark: () {},
              onNotebook: () {},
              onAi: () {},
              onTranslate: () => translated = true,
              onSettings: () {},
              onQuickTheme: () {},
              onToggleReaderMode: () {},
              onPageJump: () {},
              onZoomOut: () {},
              onZoomIn: () {},
              onFitWidth: () {},
              onFitPage: () {},
              onOcrPage: () {},
              onOcrRange: () {},
              onOcrBook: () {},
              onImageBox: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('对照翻译'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('对照翻译'));
      expect(translated, isTrue);
      await tester.ensureVisible(find.text('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('阅读设置').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (width: 600.0, scale: 1.0, dark: false),
    (width: 900.0, scale: 1.0, dark: false),
    (width: 1024.0, scale: 1.5, dark: false),
    (width: 1440.0, scale: 1.0, dark: false),
    (width: 1440.0, scale: 2.0, dark: true),
  ]) {
    testWidgets('desktop toolbar fits $scenario and keeps every action', (
      tester,
    ) async {
      var actions = 0;
      await pumpToolbar(
        tester,
        width: scenario.width,
        textScale: scenario.scale,
        dark: scenario.dark,
        onAction: () => actions += 1,
      );
      expect(tester.takeException(), isNull);
      for (final label in ['返回书库', '收起目录', '搜索', '取消书签', '笔记', 'AI', '设置']) {
        await tester.tap(find.byTooltip(label));
        await tester.pump();
      }
      expect(actions, 7);
      await tester.tap(find.byTooltip('更多阅读操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读主题与界面颜色'));
      await tester.pumpAndSettle();
      expect(actions, 8);
      final buttons = tester.widgetList<ReaderToolbarButton>(
        find.byType(ReaderToolbarButton),
      );
      expect(
        buttons
            .where((button) => button.selected)
            .map((button) => button.label),
        ['收起目录', '取消书签', '笔记'],
      );
      expect(buttons.map((button) => button.showLabel).toSet(), hasLength(1));
      if (scenario.width == 600) {
        expect(buttons.every((button) => !button.showLabel), isTrue);
      }
      if (scenario.width == 1440 && scenario.scale == 1) {
        expect(buttons.every((button) => button.showLabel), isTrue);
      }
      await captureWorkbenchWidget(
        tester,
        'reader-toolbar-${scenario.width.toInt()}-${scenario.scale}-${scenario.dark}',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow PDF toolbar keeps collapse fixed and page tools usable', (
    tester,
  ) async {
    var collapsed = false;
    var fitPage = false;
    var ocr = false;
    var rangeOcr = false;
    var bookOcr = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: RepaintBoundary(key: workbenchCaptureKey, child: child!),
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: PdfQuickToolbar(
                pageNumber: 38,
                totalPages: 206,
                settings: const ReaderSettings(),
                textLayerAvailable: false,
                pageTextAvailable: false,
                searchAvailable: false,
                capabilityReason: '测试无文本层',
                onPageJump: () {},
                onZoomOut: () {},
                onZoomIn: () {},
                onFitWidth: () {},
                onFitPage: () => fitPage = true,
                onOcrPage: () => ocr = true,
                onOcrRange: () => rangeOcr = true,
                onOcrBook: () => bookOcr = true,
                onCollapse: () => collapsed = true,
              ),
            ),
          ),
        ),
      ),
    );
    final collapse = find.byIcon(Icons.keyboard_arrow_up);
    final collapsePosition = tester.getCenter(collapse);
    expect(find.byIcon(Icons.search), findsNothing);
    expect(find.byIcon(Icons.bookmark_add_outlined), findsNothing);
    await tester.ensureVisible(find.byIcon(Icons.fullscreen_outlined));
    await tester.tap(find.byIcon(Icons.fullscreen_outlined));
    expect(find.text('识别文字'), findsOneWidget);
    await tester.tap(find.text('识别文字'));
    expect(ocr, isTrue);
    expect(find.text('识别当前页'), findsNothing);
    expect(find.byTooltip('展开识别工具'), findsNothing);
    final more = find.byTooltip('选择识别范围');
    final morePosition = tester.getCenter(more);
    expect(morePosition.dy, greaterThan(collapsePosition.dy));
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('识别当前页'), findsNothing);
    await tester.tap(find.text('识别指定页'));
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('识别整本书'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(more), morePosition);
    expect(tester.getCenter(collapse), collapsePosition);
    await tester.tap(collapse);
    expect(fitPage, isTrue);
    expect(ocr, isTrue);
    expect(rangeOcr, isTrue);
    expect(bookOcr, isTrue);
    expect(collapsed, isTrue);
    await tester.pumpAndSettle();
    await captureWorkbenchWidget(tester, 'reader-toolbar-pdf-narrow');
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('wide PDF OCR expands inside the toolbar (dark=$dark)', (
      tester,
    ) async {
      var pages = 0;
      var ranges = 0;
      var books = 0;
      final menuStates = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) =>
              RepaintBoundary(key: workbenchCaptureKey, child: child!),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 760,
                child: PdfQuickToolbar(
                  pageNumber: 18,
                  totalPages: 410,
                  settings: const ReaderSettings(),
                  onPageJump: () {},
                  onZoomOut: () {},
                  onZoomIn: () {},
                  onFitWidth: () {},
                  onFitPage: () {},
                  onOcrPage: () => pages += 1,
                  onOcrRange: () => ranges += 1,
                  onOcrBook: () => books += 1,
                  onOcrMenuChanged: menuStates.add,
                  onCollapse: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('识别文字'), findsNothing);
      expect(find.text('识别当前页'), findsNothing);
      expect(find.text('识别指定页'), findsNothing);
      expect(find.text('识别整本书'), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      final more = find.byTooltip('展开识别工具');
      expect(tester.getSize(more).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();
        expect(find.bySemanticsLabel('展开识别工具'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
      expect(
        tester.getCenter(more).dx,
        lessThan(tester.getCenter(find.byIcon(Icons.keyboard_arrow_up)).dx),
      );
      await captureWorkbenchWidget(tester, 'pdf-tools-collapsed-$dark');
      expect(pages, 0);
      expect(menuStates, isEmpty);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(menuStates, isEmpty);
      expect(more, findsNothing);
      final direct = find.widgetWithText(OutlinedButton, '识别文字');
      final toolbar = find.byType(ReaderFloatingChrome);
      expect(find.descendant(of: toolbar, matching: direct), findsOneWidget);
      expect(
        tester.getRect(toolbar).contains(tester.getCenter(direct)),
        isTrue,
      );
      expect(
        tester.getCenter(direct).dy,
        tester.getCenter(find.byIcon(Icons.fullscreen_outlined)).dy,
      );
      expect(find.byType(MenuAnchor), findsNothing);
      expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);
      await captureWorkbenchWidget(tester, 'pdf-tools-inline-$dark');
      await tester.tap(find.text('识别文字'));
      await tester.pumpAndSettle();
      expect(pages, 1);
      expect(menuStates, isEmpty);
      await tester.tap(find.byTooltip('选择识别范围'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('识别指定页'));
      await tester.pumpAndSettle();
      expect(ranges, 1);
      expect(books, 0);
      expect(menuStates, [true, false]);
      await tester.tap(find.byTooltip('选择识别范围'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('识别整本书'));
      await tester.pumpAndSettle();
      expect(books, 1);
      await tester.tap(find.byTooltip('选择识别范围'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(menuStates, [true, false, true, false, true, false]);
      expect(direct, findsOneWidget);
      expect(more, findsNothing);
      expect(pages, 1);
      expect(ranges, 1);
      expect(books, 1);
      expect(tester.takeException(), isNull);
    });
  }

  Widget pdfMenu({
    VoidCallback? onPage,
    VoidCallback? onRange,
    VoidCallback? onBook,
    ValueChanged<bool>? onMenuChanged,
    bool? pageTextAvailable,
  }) => PdfQuickToolbar(
    pageNumber: 47,
    totalPages: 613,
    settings: const ReaderSettings(),
    pageTextAvailable: pageTextAvailable,
    onPageJump: () {},
    onZoomOut: () {},
    onZoomIn: () {},
    onFitWidth: () {},
    onFitPage: () {},
    onOcrPage: onPage,
    onOcrRange: onRange,
    onOcrBook: onBook,
    onOcrMenuChanged: onMenuChanged,
    onCollapse: () {},
  );

  for (final width in [1280.0, 380.0]) {
    testWidgets('PDF direct OCR follows current page text at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      final available = ValueNotifier<bool?>(false);
      addTearDown(available.dispose);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: width < 700 ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(width < 700 ? 2 : 1)),
            child: RepaintBoundary(key: workbenchCaptureKey, child: child!),
          ),
          home: Scaffold(
            body: Center(
              child: ValueListenableBuilder<bool?>(
                valueListenable: available,
                builder: (context, value, _) => pdfMenu(
                  pageTextAvailable: value,
                  onPage: () => calls++,
                  onRange: () {},
                  onBook: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final direct = find.widgetWithText(OutlinedButton, '识别文字');
      expect(direct, findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.tap(direct);
      expect(calls, 1);
      await captureWorkbenchWidget(
        tester,
        'pdf-current-text-missing-${width.round()}',
      );
      available.value = true;
      await tester.pumpAndSettle();
      expect(find.text('识别文字'), findsNothing);
      expect(find.byTooltip('展开识别工具'), findsOneWidget);
      await captureWorkbenchWidget(
        tester,
        'pdf-current-text-available-${width.round()}',
      );
      await tester.tap(find.byTooltip('展开识别工具'));
      await tester.pumpAndSettle();
      expect(direct, findsOneWidget);
      expect(find.text('识别当前页'), findsNothing);
      expect(find.text('识别指定页'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ReaderFloatingChrome),
          matching: direct,
        ),
        findsOneWidget,
      );
      expect(find.byType(MenuAnchor), findsNothing);
      await captureWorkbenchWidget(tester, 'pdf-tools-inline-${width.round()}');
      await tester.tap(direct);
      await tester.pumpAndSettle();
      expect(calls, 2);
      available.value = null;
      await tester.pumpAndSettle();
      expect(direct, findsOneWidget);
      available.value = false;
      await tester.pumpAndSettle();
      expect(direct, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final available in ['page', 'range', 'book', 'none']) {
    testWidgets('more menu exposes only the available $available action', (
      tester,
    ) async {
      var calls = 0;
      void action() => calls++;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: pdfMenu(
              onPage: available == 'page' ? action : null,
              onRange: available == 'range' ? action : null,
              onBook: available == 'book' ? action : null,
            ),
          ),
        ),
      );
      final more = find.byTooltip('展开识别工具');
      if (available == 'none') {
        expect(more, findsNothing);
      } else {
        await tester.tap(more);
        await tester.pumpAndSettle();
        if (available == 'page') {
          expect(find.byTooltip('选择识别范围'), findsNothing);
          await tester.tap(find.text('识别文字'));
        } else {
          await tester.tap(find.byTooltip('选择识别范围'));
          await tester.pumpAndSettle();
          final items = find.byType(PopupMenuItem<VoidCallback>);
          expect(items, findsOneWidget);
          await tester.tap(items);
        }
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);
        expect(
          find.text('识别文字'),
          available == 'page' ? findsOneWidget : findsNothing,
        );
        expect(more, findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'inline OCR supports keyboard activation and stays exposed after reading',
    (tester) async {
      var pages = 0;
      final menuStates = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: pdfMenu(
                onPage: () => pages++,
                onRange: () {},
                onBook: () {},
                onMenuChanged: menuStates.add,
              ),
            ),
          ),
        ),
      );
      final more = find.byTooltip('展开识别工具');
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(pages, 1);
      expect(menuStates, isEmpty);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);
      expect(pages, 1);
      expect(menuStates, isEmpty);
      expect(find.text('识别文字'), findsOneWidget);
      expect(more, findsNothing);
    },
  );

  testWidgets('more menu fits a narrow bottom edge with large dark text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(380, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: RepaintBoundary(key: workbenchCaptureKey, child: child!),
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.bottomRight,
              child: pdfMenu(onPage: () {}, onRange: () {}, onBook: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final more = find.byTooltip('展开识别工具');
    expect(more.hitTestable(), findsOneWidget);
    await captureWorkbenchWidget(tester, 'pdf-tools-narrow-collapsed');
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('识别文字').hitTestable(), findsOneWidget);
    expect(find.text('识别指定页'), findsNothing);
    await captureWorkbenchWidget(tester, 'pdf-tools-narrow-inline');
    await tester.tap(find.byTooltip('选择识别范围'));
    await tester.pumpAndSettle();
    for (final label in ['识别指定页', '识别整本书']) {
      final action = find.text(label);
      expect(action.hitTestable(), findsOneWidget);
      final bounds = tester.getRect(action);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(380));
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(720));
    }
    await captureWorkbenchWidget(tester, 'pdf-tools-narrow-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closing OCR range options releases chrome and keeps tools inline',
    (tester) async {
      final menuStates = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: pdfMenu(
              onPage: () {},
              onRange: () {},
              onBook: () {},
              onMenuChanged: menuStates.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('展开识别工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择识别范围'));
      await tester.pumpAndSettle();
      expect(menuStates, [true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('识别指定页'), findsNothing);
      expect(find.text('识别文字').hitTestable(), findsOneWidget);
      expect(menuStates, [true, false]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('识别文字'), findsOneWidget);
      expect(menuStates, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'page text changes retain manually expanded tools without a menu lock',
    (tester) async {
      final available = ValueNotifier<bool?>(true);
      addTearDown(available.dispose);
      final menuStates = <bool>[];
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool?>(
              valueListenable: available,
              builder: (context, value, _) => pdfMenu(
                pageTextAvailable: value,
                onPage: () => calls++,
                onMenuChanged: menuStates.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('展开识别工具'));
      await tester.pumpAndSettle();
      expect(menuStates, isEmpty);
      available.value = false;
      await tester.pumpAndSettle();
      expect(menuStates, isEmpty);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      expect(find.byTooltip('选择识别范围'), findsNothing);
      expect(find.text('识别文字'), findsOneWidget);
      await tester.tap(find.text('识别文字'));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test('reader action snackbar is transient and compact', () {
    final desktopSnack = readerActionSnackBar(
      message: '已添加书签',
      actionLabel: '添加备注',
      onAction: () {},
      compact: false,
    );
    final compactSnack = readerActionSnackBar(
      message: '已添加书签',
      actionLabel: '添加备注',
      onAction: () {},
      compact: true,
    );

    expect(desktopSnack.persist, isFalse);
    expect(desktopSnack.duration, const Duration(seconds: 4));
    expect(desktopSnack.width, 420);
    expect(desktopSnack.margin, isNull);
    expect(compactSnack.persist, isFalse);
    expect(compactSnack.width, isNull);
    expect(compactSnack.margin, isNotNull);
  });

  test('reader snackbars use the quiet surface treatment', () {
    final theme = AppTheme.light();

    expect(
      theme.snackBarTheme.backgroundColor,
      theme.colorScheme.surface,
      reason: 'reader feedback should not be a full-width black inverse bar',
    );
    expect(
      theme.snackBarTheme.backgroundColor,
      isNot(theme.colorScheme.inverseSurface),
    );
    expect(theme.snackBarTheme.actionTextColor, theme.colorScheme.primary);
  });

  testWidgets('PDF toolbar exposes collapse and reveal actions', (
    tester,
  ) async {
    var collapsed = false;
    var revealed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PdfQuickToolbar(
                pageNumber: 38,
                totalPages: 206,
                settings: const ReaderSettings(),
                onPageJump: () {},
                onZoomOut: () {},
                onZoomIn: () {},
                onFitWidth: () {},
                onFitPage: () {},
                onCollapse: () => collapsed = true,
              ),
              PdfQuickToolbarReveal(
                pageNumber: 38,
                totalPages: 206,
                onReveal: () => revealed = true,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.tap(find.byType(PdfQuickToolbarReveal));

    expect(collapsed, isTrue);
    expect(revealed, isTrue);
    expect(find.text('38 / 206'), findsNWidgets(2));
  });
}

final class _ReaderChromeCaptureBinding
    extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => !captureWorkbench;
}
