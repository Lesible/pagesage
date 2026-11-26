import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/features/translation/application/translation_request_scheduler.dart';

void main() {
  late Duration elapsed;

  setUp(() {
    elapsed = Duration.zero;
  });

  Future<void> advance(WidgetTester tester, Duration duration) async {
    elapsed += duration;
    await tester.pump(duration);
  }

  testWidgets(
    'first request is immediate and queued requests wait one second',
    (tester) async {
      final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
      final calls = <Duration>[];
      final pending = [
        for (var index = 0; index < 3; index++)
          scheduler.run(
            interval: const Duration(seconds: 1),
            request: () async => calls.add(elapsed),
          ),
      ];
      await tester.pump();
      expect(calls, [Duration.zero]);
      await advance(tester, const Duration(milliseconds: 999));
      expect(calls, hasLength(1));
      await advance(tester, const Duration(milliseconds: 1));
      expect(calls, [Duration.zero, const Duration(seconds: 1)]);
      await advance(tester, const Duration(seconds: 1));
      await Future.wait(pending);
      expect(calls, [
        Duration.zero,
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
    },
  );

  testWidgets('spacing starts when the previous request finishes', (
    tester,
  ) async {
    final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
    final response = Completer<void>();
    final first = scheduler.run(
      interval: const Duration(seconds: 1),
      request: () => response.future,
    );
    var secondStarted = false;
    final second = scheduler.run(
      interval: const Duration(seconds: 1),
      request: () async => secondStarted = true,
    );
    await tester.pump();
    await advance(tester, const Duration(seconds: 5));
    expect(secondStarted, isFalse);
    response.complete();
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 999));
    expect(secondStarted, isFalse);
    await advance(tester, const Duration(milliseconds: 1));
    await first;
    await second;
    expect(secondStarted, isTrue);
  });

  testWidgets(
    'queued cancellation returns without bypassing the active request',
    (tester) async {
      final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
      final response = Completer<void>();
      final first = scheduler.run(
        interval: Duration.zero,
        request: () => response.future,
      );
      final token = AiCancelToken();
      var cancelledStarted = false;
      final cancelled = scheduler.run(
        interval: const Duration(seconds: 60),
        cancelToken: token,
        request: () async => cancelledStarted = true,
      );
      final cancellation = expectLater(
        cancelled,
        throwsA(isA<AiChatCancelledException>()),
      );
      var thirdStarted = false;
      final third = scheduler.run(
        interval: Duration.zero,
        request: () async => thirdStarted = true,
      );
      await tester.pump();
      token.cancel();
      await tester.pump();
      await cancellation;
      expect(cancelledStarted, isFalse);
      expect(thirdStarted, isFalse);
      response.complete();
      await tester.pump();
      await first;
      await third;
      expect(cancelledStarted, isFalse);
      expect(thirdStarted, isTrue);
    },
  );

  testWidgets('cancelling during cooldown releases its timer and queue slot', (
    tester,
  ) async {
    final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
    await scheduler.run(interval: Duration.zero, request: () async {});
    final token = AiCancelToken();
    var cancelledStarted = false;
    final cancelled = scheduler.run(
      interval: const Duration(seconds: 60),
      cancelToken: token,
      request: () async => cancelledStarted = true,
    );
    final cancellation = expectLater(
      cancelled,
      throwsA(isA<AiChatCancelledException>()),
    );
    var nextStarted = false;
    final next = scheduler.run(
      interval: Duration.zero,
      request: () async => nextStarted = true,
    );
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 100));
    token.cancel();
    await tester.pump();
    await cancellation;
    await next;
    expect(cancelledStarted, isFalse);
    expect(nextStarted, isTrue);
  });

  testWidgets(
    'failed requests retain the cooldown and do not poison the queue',
    (tester) async {
      final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
      final failed = scheduler.run<void>(
        interval: const Duration(seconds: 1),
        request: () async => throw StateError('test failure'),
      );
      final failure = expectLater(failed, throwsStateError);
      var nextStarted = false;
      final next = scheduler.run(
        interval: Duration.zero,
        request: () async => nextStarted = true,
      );
      await tester.pump();
      await failure;
      expect(nextStarted, isFalse);
      await advance(tester, const Duration(seconds: 1));
      await next;
      expect(nextStarted, isTrue);
    },
  );

  testWidgets('switching profiles respects the larger adjacent interval', (
    tester,
  ) async {
    final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
    final calls = <Duration>[];
    final pending = [
      for (final seconds in [1, 2, 0])
        scheduler.run(
          interval: Duration(seconds: seconds),
          request: () async => calls.add(elapsed),
        ),
    ];
    await tester.pump();
    await advance(tester, const Duration(seconds: 1));
    expect(calls, [Duration.zero]);
    await advance(tester, const Duration(seconds: 1));
    expect(calls, [Duration.zero, const Duration(seconds: 2)]);
    await advance(tester, const Duration(seconds: 2));
    await Future.wait(pending);
    expect(calls, [
      Duration.zero,
      const Duration(seconds: 2),
      const Duration(seconds: 4),
    ]);
  });

  testWidgets('an already cancelled request never enters the queue', (
    tester,
  ) async {
    final scheduler = TranslationRequestScheduler(elapsed: () => elapsed);
    final token = AiCancelToken()..cancel();
    await expectLater(
      scheduler.run<void>(
        interval: const Duration(seconds: 60),
        cancelToken: token,
        request: () async => fail('Cancelled request must not run'),
      ),
      throwsA(isA<AiChatCancelledException>()),
    );
    var started = false;
    await scheduler.run(
      interval: Duration.zero,
      request: () async => started = true,
    );
    expect(started, isTrue);
  });
}
