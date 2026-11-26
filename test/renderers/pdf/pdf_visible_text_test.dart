import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/features/reader/presentation/reader_ocr_overlay_controller.dart';
import 'package:pagesage/renderers/common/renderer_event.dart';
import 'package:pagesage/renderers/pdf/pdf_canvas_view.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pdf-visible-text-');
    file = await File('${directory.path}/mixed.pdf').writeAsBytes(_mixedPdf());
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> waitForText(
    WidgetTester tester,
    List<RendererEvent> events, {
    required bool available,
    int? page,
  }) async {
    await tester.runAsync(() async {
      for (var round = 0; round < 100; round++) {
        await tester.pump(const Duration(milliseconds: 25));
        await Future<void>.delayed(const Duration(milliseconds: 15));
        final status = events
            .whereType<RendererVisibleTextChanged>()
            .lastOrNull;
        if (status?.available == available &&
            (page == null || status?.pageNumber == page)) {
          return;
        }
      }
    });
    final statuses = events.whereType<RendererVisibleTextChanged>();
    expect(statuses, isNotEmpty);
    expect(statuses.last.available, available);
    if (page != null) expect(statuses.last.pageNumber, page);
  }

  Future<
    ({
      List<RendererEvent> events,
      ValueNotifier<int> page,
      ValueNotifier<ReaderSettings> settings,
      ReaderOcrOverlayController overlays,
    })
  >
  mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.reset);
    final events = <RendererEvent>[];
    final page = ValueNotifier(1);
    final settings = ValueNotifier(
      const ReaderSettings(readerMode: ReaderMode.paged),
    );
    final overlays = ReaderOcrOverlayController();
    addTearDown(page.dispose);
    addTearDown(settings.dispose);
    addTearDown(overlays.dispose);
    final changes = Listenable.merge([page, settings, overlays]);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: changes,
              builder: (context, _) => PdfCanvasView(
                book: Book(
                  id: 'mixed',
                  title: 'Mixed text fixture',
                  format: BookFormat.pdf,
                  libraryFilePath: file.path,
                  fileHash: 'test-only',
                  fileSize: file.lengthSync(),
                  createdAt: 1,
                  updatedAt: 1,
                ),
                settings: settings.value,
                initialProgress: ReadingProgressSnapshot(
                  bookId: 'mixed',
                  locator: ReadingLocator.pdf(page: page.value),
                  progress: 0,
                  updatedAt: 1,
                ),
                jumpToken: page.value,
                annotations: const [],
                ocrOverlayPage: overlays.state.page,
                ocrOverlayBlocks: overlays.state.blocks,
                ocrOverlayToken: overlays.state.token,
                onEvent: events.add,
              ),
            ),
          ),
        ),
      ),
    );
    await waitForText(tester, events, available: true, page: 1);
    return (events: events, page: page, settings: settings, overlays: overlays);
  }

  testWidgets('mixed PDF reports the active page rather than document text', (
    tester,
  ) async {
    final state = await mount(tester);
    expect(
      state.events.whereType<RendererCapabilityChanged>().last.nativeTextLayer,
      isTrue,
    );
    for (final next in [
      (page: 2, available: false),
      (page: 3, available: true),
      (page: 4, available: false),
      (page: 2, available: false),
    ]) {
      state.events.clear();
      state.page.value = next.page;
      await waitForText(
        tester,
        state.events,
        available: next.available,
        page: next.page,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR is scoped to its page and remains usable after returning', (
    tester,
  ) async {
    final state = await mount(tester);
    state.page.value = 2;
    await waitForText(tester, state.events, available: false, page: 2);
    const blocks = [
      {
        'text': 'Recognized source',
        'left': .1,
        'top': .2,
        'width': .5,
        'height': .05,
      },
    ];
    state.events.clear();
    state.overlays.show([(page: 4, blocks: blocks)]);
    await waitForText(tester, state.events, available: false, page: 2);
    state.events.clear();
    state.overlays.show([(page: 2, blocks: blocks)]);
    await waitForText(tester, state.events, available: true, page: 2);
    state.events.clear();
    state.page.value = 3;
    await waitForText(tester, state.events, available: true, page: 3);
    state.events.clear();
    state.page.value = 2;
    await waitForText(tester, state.events, available: true, page: 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('double page requires usable text on both visible pages', (
    tester,
  ) async {
    final state = await mount(tester);
    state.page.value = 3;
    await waitForText(tester, state.events, available: true, page: 3);
    state.events.clear();
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pump();
    await waitForText(tester, state.events, available: false);
    state.events.clear();
    state.overlays.show([
      (
        page: 2,
        blocks: [
          {
            'text': 'Second page OCR',
            'left': .1,
            'top': .2,
            'width': .5,
            'height': .05,
          },
        ],
      ),
    ]);
    await waitForText(tester, state.events, available: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('continuous mode updates current text after a jump', (
    tester,
  ) async {
    final state = await mount(tester);
    state.settings.value = state.settings.value.copyWith(
      readerMode: ReaderMode.continuous,
    );
    await tester.pump();
    state.events.clear();
    state.page.value = 2;
    await waitForText(tester, state.events, available: false, page: 2);
    state.events.clear();
    state.page.value = 3;
    await waitForText(tester, state.events, available: true, page: 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'rapid navigation discards old page results and survives closing',
    (tester) async {
      final state = await mount(tester);
      state.events.clear();
      for (final page in [2, 4, 3]) {
        state.page.value = page;
        await tester.pump(const Duration(milliseconds: 10));
      }
      await waitForText(tester, state.events, available: true, page: 3);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      expect(
        state.events.whereType<RendererVisibleTextChanged>().last.pageNumber,
        3,
      );
      state.page.value = 4;
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

List<int> _mixedPdf() {
  const count = 4;
  const font = 3 + count * 2;
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(count, (index) => '${3 + index * 2} 0 R').join(' ')}] /Count $count >>',
    for (var index = 0; index < count; index++) ...[
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents ${4 + index * 2} 0 R /Resources << /Font << /F1 $font 0 R >> >> >>',
      () {
        final operations = index.isEven
            ? 'BT /F1 12 Tf 72 720 Td (Text page ${index + 1}) Tj ET'
            : 'q 0.9 g 72 500 200 100 re f Q';
        return '<< /Length ${operations.length} >>\nstream\n$operations\nendstream';
      }(),
    ],
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(buffer.length);
    buffer.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(buffer.toString());
}
