import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/translation/reading_translation.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/domain/translation/translation_segments.dart';
import 'package:pagesage/features/translation/data/reading_translation_source.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';

import 'reading_translation_fixture.dart';

void main() {
  late ReadingTranslationFixture fixture;
  setUp(() async => fixture = await ReadingTranslationFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'completed units survive close/reopen and cached reads make no request even without credentials',
    () async {
      final source = translationSource();
      final first = fixture.controller();
      await first.open(source, profileId: 'service');
      await first.translateMissing();
      expect(first.completed, 2);
      expect(first.unsavedCount, 0);
      final fingerprint = first.selectedFingerprint!;
      first.dispose();
      expect(fixture.gateway.calls, hasLength(2));
      await fixture.reopen();
      final second = fixture.controller();
      addTearDown(second.dispose);
      await second.open(source, savedFingerprint: fingerprint);
      expect(
        second.translations.values,
        unorderedEquals(['译文：First paragraph', '译文：Second paragraph']),
      );
      expect(second.canTranslate, isFalse);
      expect(fixture.gateway.calls, hasLength(2));
    },
  );

  test(
    'repeat open with the same service reuses cache and language/source changes cannot reuse it',
    () async {
      final controller = fixture.controller();
      addTearDown(controller.dispose);
      await controller.open(translationSource(), profileId: 'service');
      await controller.translateMissing();
      await controller.open(translationSource(), profileId: 'service');
      await controller.translateMissing();
      expect(fixture.gateway.calls, hasLength(2));
      await controller.open(
        translationSource(),
        profileId: 'service',
        language: 'en',
      );
      expect(controller.completed, 0);
      await controller.translateMissing();
      expect(fixture.gateway.targets, ['zh', 'zh', 'en', 'en']);
      await controller.open(
        translationSource(key: 'snapshot-two'),
        profileId: 'service',
      );
      expect(controller.completed, 0);
    },
  );

  test(
    'changing request interval preserves cached translations without another request',
    () async {
      final controller = fixture.controller();
      addTearDown(controller.dispose);
      final source = translationSource();
      await controller.open(source, profileId: 'service');
      await controller.translateMissing();
      final fingerprint = controller.selectedFingerprint;
      final profile = (await fixture.settings.getSettings()).profiles.single;
      await fixture.settings.saveProfile(
        TranslationProfile.fromJson({
          ...profile.toJson(),
          'requestIntervalMs': 2500,
        }),
      );
      await controller.open(source, profileId: 'service');
      await controller.translateMissing();
      expect(controller.selectedFingerprint, fingerprint);
      expect(controller.completed, 2);
      expect(fixture.gateway.calls, hasLength(2));
    },
  );

  test(
    'partial failure persists successful units and retry requests only missing units',
    () async {
      var fail = true;
      fixture.gateway.respond = (text, token) async {
        if (text.startsWith('Second') && fail) {
          throw const TranslationException('限流');
        }
        return TranslationResult(text: '完成：$text');
      };
      final controller = fixture.controller();
      addTearDown(controller.dispose);
      await controller.open(translationSource(), profileId: 'service');
      await controller.translateMissing();
      expect(controller.completed, 1);
      expect(controller.error, '限流');
      expect(
        await fixture.repository.load('book', 'snapshot-one'),
        hasLength(1),
      );
      fail = false;
      await controller.translateMissing();
      expect(controller.completed, 2);
      expect(fixture.gateway.calls, [
        'First paragraph',
        'Second paragraph',
        'Second paragraph',
      ]);
    },
  );

  test(
    'cancel and source switch discard late network results and duplicate clicks do not start another job',
    () async {
      final arrived = Completer<void>();
      final release = Completer<TranslationResult>();
      fixture.gateway.respond = (text, token) {
        if (!arrived.isCompleted) arrived.complete();
        return release.future;
      };
      final controller = fixture.controller();
      addTearDown(controller.dispose);
      await controller.open(translationSource(), profileId: 'service');
      final job = controller.translateMissing();
      await arrived.future;
      await controller.translateMissing();
      expect(fixture.gateway.calls, hasLength(1));
      controller.cancel();
      expect(controller.cancelled, isTrue);
      await controller.open(
        translationSource(key: 'new-page'),
        profileId: 'service',
      );
      release.complete(const TranslationResult(text: '迟到的旧页'));
      await job;
      expect(controller.source?.key, 'new-page');
      expect(controller.completed, 0);
      expect(await fixture.repository.load('book', 'snapshot-one'), isEmpty);
    },
  );

  test(
    'a long paragraph persists each piece and restarting retries only missing pieces',
    () async {
      final text =
          '${'Alpha ' * 150}End one. ${'Beta ' * 150}End two. ${'Gamma ' * 100}';
      final source = translationSource(texts: [text]);
      final chunks = splitTranslationText(text);
      var failed = false;
      fixture.gateway.respond = (input, _) async {
        if (!failed && fixture.gateway.calls.length == 2) {
          failed = true;
          throw const TranslationException('暂时限流');
        }
        return TranslationResult(text: input);
      };
      final first = fixture.controller();
      await first.open(source, profileId: 'service');
      await first.translateMissing();
      expect(first.completed, 0);
      expect(await fixture.repository.load('book', source.key), hasLength(1));
      first.dispose();
      final resumed = fixture.controller();
      addTearDown(resumed.dispose);
      await resumed.open(source, profileId: 'service');
      await resumed.translateMissing();
      expect(resumed.translations['0:0'], text);
      expect(fixture.gateway.calls, hasLength(chunks.length + 1));
      expect(
        fixture.gateway.calls.where((input) => input == chunks.first.trim()),
        hasLength(1),
      );
    },
  );

  test('empty response never becomes a completed cache row', () async {
    fixture.gateway.respond = (_, _) async =>
        const TranslationResult(text: ' ');
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.open(translationSource(), profileId: 'service');
    await controller.translateMissing();
    expect(controller.completed, 0);
    expect(controller.error, contains('空译文'));
    expect(await fixture.repository.load('book', 'snapshot-one'), isEmpty);
  });

  test(
    'write failure retains received translation and retry saves before requesting more text',
    () async {
      final repository = _FailOnceRepository(fixture.repository);
      final controller = fixture.controller(repository: repository);
      addTearDown(controller.dispose);
      await controller.open(translationSource(), profileId: 'service');
      await controller.translateMissing();
      expect(controller.completed, 1);
      expect(controller.unsavedCount, 1);
      expect(controller.error, contains('保存失败'));
      await controller.translateMissing();
      expect(controller.completed, 2);
      expect(controller.unsavedCount, 0);
      expect(fixture.gateway.calls, ['First paragraph', 'Second paragraph']);
      expect(
        await fixture.repository.load('book', 'snapshot-one'),
        hasLength(2),
      );
    },
  );

  test(
    'renaming configuration preserves semantic cache identity while changing endpoint invalidates it',
    () async {
      final before = await fixture.service.planFor('service');
      final stored = (await fixture.settings.getSettings()).profiles.single;
      await fixture.settings.saveProfile(
        TranslationProfile(
          id: stored.id,
          name: '新名字',
          provider: stored.provider,
          endpoint: stored.endpoint,
          protocol: stored.protocol,
          revision: stored.revision,
        ),
      );
      final renamed = await fixture.service.planFor('service');
      expect(renamed.fingerprint, before.fingerprint);
      final current = (await fixture.settings.getSettings()).profiles.single;
      await fixture.settings.saveProfile(
        TranslationProfile(
          id: current.id,
          name: current.name,
          provider: current.provider,
          endpoint: 'http://127.0.0.1:1234/other',
          protocol: current.protocol,
          revision: current.revision,
        ),
      );
      expect(
        (await fixture.service.planFor('service')).fingerprint,
        isNot(before.fingerprint),
      );
      await expectLater(
        fixture.service.translateWithPlan(before, text: 'old'),
        throwsA(isA<TranslationException>()),
      );
      expect(fixture.gateway.calls, isEmpty);
    },
  );

  test(
    'inline code, math, URLs and spaces remain exact, and bounded Unicode splitting is lossless',
    () async {
      const text = 'Use fn() with x+y at https://example.test/a.';
      final parts = protectedTranslationParts(
        const EpubTextBlock(
          startOffset: 100,
          endOffset: 144,
          text: text,
          type: EpubBlockType.paragraph,
          runs: [
            EpubInlineRun(start: 104, end: 108, style: EpubInlineStyle.code),
            EpubInlineRun(start: 114, end: 117, style: EpubInlineStyle.math),
          ],
        ),
      );
      expect(parts.map((part) => part.text).join(), text);
      expect(parts.where((part) => part.protected).map((part) => part.text), [
        'fn()',
        'x+y',
        'https://example.test/a.',
      ]);
      final source = ReadingTranslationSource(
        bookId: 'book',
        key: 'protected',
        label: '原文',
        units: [
          ReadingTranslationUnit(id: '0:100', original: text, parts: parts),
        ],
      );
      fixture.gateway.respond = (text, _) async =>
          TranslationResult(text: text.toUpperCase());
      final controller = fixture.controller();
      addTearDown(controller.dispose);
      await controller.open(source, profileId: 'service');
      await controller.translateMissing();
      expect(
        controller.translations['0:100'],
        'USE fn() WITH x+y AT https://example.test/a.',
      );
      expect(fixture.gateway.calls, ['Use', 'with', 'at']);
      final long = '很长的文本 🦉 and text. ' * 300;
      final chunks = splitTranslationText(long);
      expect(chunks.join(), long);
      expect(chunks.every((chunk) => chunk.runes.length <= 900), isTrue);
      expect(chunks.any((chunk) => chunk.contains('\uFFFD')), isFalse);
    },
  );
}

final class _FailOnceRepository implements ReadingTranslationRepository {
  _FailOnceRepository(this.inner);
  final ReadingTranslationRepository inner;
  bool fail = true;
  @override
  Future<List<SavedReadingTranslation>> load(String bookId, String sourceKey) =>
      inner.load(bookId, sourceKey);
  @override
  Future<void> save(SavedReadingTranslation translation) async {
    if (fail) {
      fail = false;
      throw StateError('disk full');
    }
    await inner.save(translation);
  }
}
