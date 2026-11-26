import 'dart:async';

import '../../../domain/ai/ai_models.dart';

final class TranslationRequestScheduler {
  TranslationRequestScheduler({Duration Function()? elapsed})
    : _elapsed = elapsed ?? _monotonicClock();

  final Duration Function() _elapsed;
  Future<void> _tail = Future<void>.value();
  Duration? _lastFinished;
  Duration _lastInterval = Duration.zero;

  Future<T> run<T>({
    required Duration interval,
    required Future<T> Function() request,
    AiCancelToken? cancelToken,
  }) {
    if (cancelToken?.isCancelled == true) {
      return Future<T>.error(const AiChatCancelledException());
    }
    final cancelled = Completer<T>();
    cancelToken?.bind(() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const AiChatCancelledException());
      }
    });
    final scheduled = _tail.then((_) async {
      if (cancelToken?.isCancelled == true) {
        throw const AiChatCancelledException();
      }
      final finished = _lastFinished;
      if (finished != null) {
        final spacing = interval > _lastInterval ? interval : _lastInterval;
        final remaining = spacing - (_elapsed() - finished);
        if (remaining > Duration.zero) {
          final waited = Completer<T?>();
          final timer = Timer(remaining, () => waited.complete());
          try {
            await Future.any<T?>([waited.future, cancelled.future]);
          } finally {
            timer.cancel();
          }
        }
      }
      if (cancelToken?.isCancelled == true) {
        throw const AiChatCancelledException();
      }
      try {
        return await request();
      } finally {
        _lastFinished = _elapsed();
        _lastInterval = interval;
      }
    });
    _tail = scheduled.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return cancelToken == null
        ? scheduled
        : Future.any<T>([scheduled, cancelled.future]);
  }

  static Duration Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }
}
