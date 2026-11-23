import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagesage/core/ocr/method_channel_ocr_engine.dart';
import 'package:pagesage/core/ocr/method_channel_pdf_page_rasterizer.dart';
import 'package:pagesage/domain/ocr/ocr_models.dart';
import 'package:pagesage/features/ocr/application/ocr_providers.dart';

import '../tool/generate_manual_samples.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iPad uses real Vision OCR and CoreGraphics raster channels',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final engine = container.read(ocrEngineProvider);
      final rasterizer = container.read(pdfPageRasterizerProvider);
      expect(engine, isA<MethodChannelOcrEngine>());
      expect(engine.id, 'ios-vision');
      expect(rasterizer, isA<MethodChannelPdfPageRasterizer>());

      final root = await Directory.systemTemp.createTemp('pagesage_ipad_ocr_');
      addTearDown(() => root.delete(recursive: true));
      final pdf = File('${root.path}/ocr.pdf');
      await pdf.writeAsBytes(buildTextPdf(const ['PageSage RunbookToken']));
      final image = await rasterizer.renderPage(
        filePath: pdf.path,
        pageNumber: 1,
        maxPixels: 1000000,
      );
      expect(image.bytes.length, greaterThan(1000));
      expect(image.width * image.height, lessThanOrEqualTo(1005000));
      expect(await engine.isAvailable(), isTrue);
      expect(await engine.supportedLanguages(), isNotEmpty);
      final result = await engine.recognize(
        imageBytes: image.bytes,
        languageHint: 'en',
      );
      expect(result.engine, 'ios-vision');
      expect(result.text.toLowerCase(), contains('pagesage'));
      expect(result.blocks, isNotEmpty);
      for (final block in result.blocks) {
        expect(block.left, inInclusiveRange(0, 1));
        expect(block.top, inInclusiveRange(0, 1));
        expect(block.width, inInclusiveRange(0, 1));
        expect(block.height, inInclusiveRange(0, 1));
      }

      await expectLater(
        engine.recognizePdfPage(
          filePath: pdf.path,
          pageNumber: 99,
          languageHint: 'en',
        ),
        throwsA(isA<OcrFailedException>()),
      );
      await expectLater(
        engine.recognizePdfPage(
          filePath: '${root.path}/missing.pdf',
          pageNumber: 1,
          languageHint: 'en',
        ),
        throwsA(isA<OcrFailedException>()),
      );
      await expectLater(
        engine.recognizePdfPage(
          filePath: pdf.path,
          pageNumber: 1,
          languageHint: 'invalid-language',
        ),
        throwsA(isA<OcrUnavailableException>()),
      );

      final rotated = File('${root.path}/rotated.pdf');
      await rotated.writeAsBytes(
        buildTextPdf(const ['Rotated PageSage'], rotate: 90),
      );
      final rotatedResult = await engine.recognizePdfPage(
        filePath: rotated.path,
        pageNumber: 1,
        languageHint: 'en',
      );
      expect(rotatedResult.text.toLowerCase(), contains('rotated'));
      expect(
        rotatedResult.imageWidth!,
        greaterThan(rotatedResult.imageHeight!),
      );
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isIOS,
  );
}
