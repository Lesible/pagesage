import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:pagesage_web_capture_eval/article_extractor.dart';
import 'package:pagesage_web_capture_eval/evaluation.dart';
import 'package:pagesage_web_capture_eval/native_article.dart';
import 'package:xml/xml.dart';

void main(List<String> arguments) {
  final options = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    if (index + 1 >= arguments.length ||
        !const {
          '--output',
          '--samples',
          '--iterations',
        }.contains(arguments[index])) {
      throw const FormatException(
        '用法：evaluate.dart --output <directory> '
        '[--samples <directory>] [--iterations 30]',
      );
    }
    options[arguments[index]] = arguments[index + 1];
  }
  final outputPath = options['--output'];
  if (outputPath == null) {
    throw const FormatException('需要显式指定 --output');
  }
  final iterations = int.tryParse(options['--iterations'] ?? '30');
  if (iterations == null || iterations < 1 || iterations > 100) {
    throw const FormatException('iterations 需要在 1–100 之间');
  }
  final output = Directory(outputPath)..createSync(recursive: true);
  final fixtureSource = File('fixtures/cases.json').readAsStringSync();
  final fixtures = (jsonDecode(fixtureSource) as List<Object?>)
      .cast<Map<String, Object?>>();
  const extractor = ArticleExtractor();
  final cases = <Map<String, Object?>>[];
  for (final fixture in fixtures) {
    final candidates = <String, Object?>{};
    for (final strategy in ExtractionStrategy.values) {
      final measured = _measure(
        () => extractor.extract(
          source: fixture['html']! as String,
          pageUrl: Uri.parse('https://example.test/articles/page.html'),
          strategy: strategy,
        ),
        iterations,
      );
      final score = scoreExtraction(
        measured.result,
        expected: (fixture['expected']! as List<Object?>).cast<String>(),
        shouldReject: fixture['reject'] == true,
      );
      candidates[strategy.name] = {
        'passes': score.passes,
        'retention': score.retention,
        'noise': score.noise,
        ..._describe(measured.result),
        'elapsed': measured.times,
      };
    }
    cases.add({'id': fixture['id'], 'candidates': candidates});
  }
  final publicPages = <Map<String, Object?>>[];
  final checks =
      jsonDecode(File('fixtures/public-checks.json').readAsStringSync())
          as Map<String, Object?>;
  final samplePath = options['--samples'];
  if (samplePath != null) {
    final manifest =
        (jsonDecode(File('$samplePath/manifest.json').readAsStringSync())
                as List<Object?>)
            .cast<Map<String, Object?>>();
    for (final sample in manifest) {
      if (sample['error'] != null) {
        publicPages.add({'id': sample['id'], 'fetchError': sample['error']});
        continue;
      }
      final source = File('$samplePath/${sample['path']}').readAsStringSync();
      final candidates = <String, Object?>{};
      for (final strategy in ExtractionStrategy.values) {
        final measured = _measure(
          () => extractor.extract(
            source: source,
            pageUrl: Uri.parse(sample['finalUrl']! as String),
            strategy: strategy,
          ),
          iterations,
        );
        final details = _describe(measured.result);
        final check = checks[sample['id']] as Map<String, Object?>?;
        final anchors = (check?['anchors'] as List<Object?>? ?? [])
            .cast<String>();
        final missing = anchors
            .where(
              (anchor) => !normalizeForEvaluation(
                measured.result.text,
              ).contains(normalizeForEvaluation(anchor)),
            )
            .toList();
        final meetsStructure =
            [
              ('minimumImages', 'images'),
              ('minimumCodeBlocks', 'preBlocks'),
              ('minimumTables', 'tableBlocks'),
            ].every(
              (keys) =>
                  (details[keys.$2] as int? ?? 0) >=
                  (check?[keys.$1] as int? ?? 0),
            );
        candidates[strategy.name] = {
          ...details,
          'missingAnchors': missing,
          'structureChecksPass': meetsStructure,
          'sampleChecksPass':
              check != null &&
              missing.isEmpty &&
              meetsStructure &&
              measured.result.isReadable,
          'elapsed': measured.times,
        };
        if (measured.result.isReadable) {
          File(
            '${output.path}/${sample['id']}-${strategy.name}.xhtml',
          ).writeAsStringSync(measured.result.xhtml);
        }
      }
      publicPages.add({
        'id': sample['id'],
        'inputSha256': sha256.convert(utf8.encode(source)).toString(),
        'inputBytes': utf8.encode(source).length,
        'candidates': candidates,
      });
    }
  }
  final fixtureGatePass = cases.every((entry) {
    final candidates = entry['candidates']! as Map<String, Object?>;
    return (candidates['semantic']! as Map<String, Object?>)['passes'] == true;
  });
  final sampleGatePass = publicPages.every((entry) {
    final candidates = entry['candidates'] as Map<String, Object?>?;
    final selected = candidates?['semantic'] as Map<String, Object?>?;
    final gaps = selected?['nativeGaps'] as Map<String, int>?;
    return selected?['sampleChecksPass'] == true &&
        selected?['nativeOffsetsValid'] == true &&
        gaps != null &&
        gaps.values.every((value) => value == 0);
  });
  final summary = <String, Object?>{
    'version': 1,
    'fixtureSha256': sha256.convert(utf8.encode(fixtureSource)).toString(),
    'iterations': iterations,
    'platform': Platform.operatingSystem,
    'dartVersion': Platform.version,
    'rssBytesAtEnd': ProcessInfo.currentRss,
    'maxRssBytes': ProcessInfo.maxRss,
    'selectedStrategy': 'semantic',
    'selectedGatePass': fixtureGatePass && sampleGatePass,
    'fixtures': cases,
    'publicPages': publicPages,
  };
  File(
    '${output.path}/report.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
  for (final strategy in ExtractionStrategy.values) {
    final passed = cases.where((entry) {
      final candidates = entry['candidates']! as Map<String, Object?>;
      final result = candidates[strategy.name]! as Map<String, Object?>;
      return result['passes'] == true;
    }).length;
    stdout.writeln('${strategy.name}: $passed/${cases.length} fixtures pass');
  }
  stdout.writeln('public samples: ${publicPages.length}');
  stdout.writeln('report written to ${output.path}/report.json');
  if (!fixtureGatePass || !sampleGatePass) {
    stderr.writeln('selected strategy failed fixture or public sample checks');
    exitCode = 1;
  }
}

({ArticleExtraction result, Map<String, double> times}) _measure(
  ArticleExtraction Function() run,
  int iterations,
) {
  final coldTimer = Stopwatch()..start();
  final result = run();
  coldTimer.stop();
  final times = <int>[];
  for (var iteration = 0; iteration < iterations; iteration += 1) {
    final watch = Stopwatch()..start();
    run();
    watch.stop();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return (
    result: result,
    times: {
      'firstMs': coldTimer.elapsedMicroseconds / 1000,
      'medianMs': times[times.length ~/ 2] / 1000,
      'p95Ms': times[math.max(0, (times.length * 0.95).ceil() - 1)] / 1000,
    },
  );
}

Map<String, Object?> _describe(ArticleExtraction result) {
  if (!result.isReadable) {
    return {'readable': false, 'failure': result.failure!.name};
  }
  final xml = XmlDocument.parse(result.xhtml);
  final body = xml.findAllElements('body').single;
  final nativeWatch = Stopwatch()..start();
  final native = toNativeDocument(result);
  nativeWatch.stop();
  final legacy = toLegacyNativeDocument(result);
  final chapter = native.chapters.single;
  final codes = body.findAllElements('pre').toList();
  final tables = body.findAllElements('table').length;
  final links = body
      .findAllElements('a')
      .where(
        (element) =>
            element.getAttribute('href') != null &&
            element.innerText.trim().isNotEmpty,
      )
      .length;
  Map<String, int> gaps(EpubDocument document) {
    final blocks = document.chapters.single.blocks;
    final nativeText = blocks.whereType<EpubTextBlock>().toList();
    final codeText = nativeText
        .where((block) => block.type == EpubBlockType.code)
        .map((block) => block.text.trim())
        .toList();
    codeText.addAll(
      blocks
          .whereType<EpubTableBlock>()
          .expand((table) => table.cells)
          .expand((row) => row)
          .map((cell) => cell.text),
    );
    return {
      'codeWhitespaceLost': codes
          .where(
            (element) => !codeText.any(
              (text) => text.contains(element.innerText.trim()),
            ),
          )
          .length,
      'tableStructureLost': math.max(
        0,
        tables - blocks.whereType<EpubTableBlock>().length,
      ),
      'linkTargetsLost': math.max(
        0,
        links -
            nativeText
                .expand((block) => block.runs)
                .where((run) => run.style == EpubInlineStyle.link)
                .length -
            blocks
                .whereType<EpubTableBlock>()
                .expand((table) => table.cells)
                .expand((row) => row)
                .expand((cell) => cell.runs)
                .where((run) => run.style == EpubInlineStyle.link)
                .length,
      ),
    };
  }

  return {
    'readable': true,
    'textLength': result.text.length,
    'images': result.images.length,
    'warnings': result.warnings.map((warning) => warning.name).toList(),
    'headings': chapter.blocks
        .whereType<EpubTextBlock>()
        .where((block) => block.type == EpubBlockType.heading)
        .length,
    'preBlocks': codes.length,
    'tableBlocks': tables,
    'links': links,
    'nativeParseMs': nativeWatch.elapsedMicroseconds / 1000,
    'nativeGaps': gaps(native),
    'legacyNativeGaps': gaps(legacy),
    'nativeOffsetsValid': chapter.blocks.whereType<EpubTextBlock>().every(
      (block) =>
          chapter.text.substring(block.startOffset, block.endOffset) ==
          block.text,
    ),
  };
}
