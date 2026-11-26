import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/ai/ai_models.dart';
import '../../../domain/translation/reading_translation.dart';
import '../../../domain/translation/translation_models.dart';
import '../../../domain/translation/translation_segments.dart';
import 'translation_service.dart';

final class ReadingTranslationController extends ChangeNotifier {
  ReadingTranslationController({
    required this.repository,
    required this.service,
  });
  final ReadingTranslationRepository repository;
  final TranslationService service;
  ReadingTranslationSource? source;
  TranslationPlan? plan;
  List<SavedReadingTranslation> saved = const [];
  final Map<String, String> translations = {};
  final Map<String, SavedReadingTranslation> _unsaved = {};
  final Map<String, SavedReadingTranslation> _received = {};
  final Map<String, List<SavedReadingTranslation>> _pendingSources = {};
  String? error;
  String? selectedFingerprint;
  String targetLanguage = 'zh';
  bool loading = false;
  bool running = false;
  bool cancelled = false;
  int _generation = 0;
  AiCancelToken? _cancel;
  bool _disposed = false;
  bool get canTranslate =>
      plan != null && source?.units.isNotEmpty == true && !loading && !running;
  int get completed => translations.length;
  int get unsavedCount => _unsaved.length;
  int get savedPieceCount =>
      saved.where((row) => row.fingerprint == selectedFingerprint).length;

  Future<void> open(
    ReadingTranslationSource next, {
    String? profileId,
    String? language,
    String? savedFingerprint,
  }) async {
    cancel(notify: false);
    final generation = ++_generation;
    final previous = source;
    if (previous != null && _unsaved.isNotEmpty) {
      final key = '${previous.bookId}|${previous.key}';
      final pending = {
        for (final row in _pendingSources[key] ?? <SavedReadingTranslation>[])
          row.id: row,
      };
      pending.addAll({for (final row in _unsaved.values) row.id: row});
      _pendingSources[key] = pending.values.toList();
    }
    source = next;
    loading = true;
    error = null;
    plan = null;
    selectedFingerprint = null;
    saved = const [];
    translations.clear();
    _unsaved.clear();
    _received.clear();
    notifyListeners();
    try {
      final rows = await repository.load(next.bookId, next.key);
      if (!_current(generation)) return;
      saved = rows;
      TranslationPlan? resolved;
      if (savedFingerprint == null && profileId != null) {
        try {
          resolved = await service.planFor(profileId, targetLanguage: language);
        } on TranslationException catch (failure) {
          if (_current(generation)) error = failure.message;
        }
      }
      if (!_current(generation)) return;
      plan = resolved;
      final fallback = rows
          .where(
            (row) =>
                (language == null || row.targetLanguage == language) &&
                (profileId == null || row.profileId == profileId),
          )
          .firstOrNull;
      selectedFingerprint =
          savedFingerprint ?? resolved?.fingerprint ?? fallback?.fingerprint;
      targetLanguage =
          resolved?.profile.targetLanguage ??
          language ??
          rows
              .where((row) => row.fingerprint == selectedFingerprint)
              .firstOrNull
              ?.targetLanguage ??
          'zh';
      for (final row in rows) {
        if (row.fingerprint == selectedFingerprint) {
          _received.putIfAbsent(row.unitId, () => row);
        }
      }
      for (final pending
          in _pendingSources['${next.bookId}|${next.key}'] ??
              <SavedReadingTranslation>[]) {
        if (pending.fingerprint == selectedFingerprint &&
            !_received.containsKey(pending.unitId)) {
          _received[pending.unitId] = pending;
          _unsaved[pending.unitId] = pending;
        }
      }
      for (final unit in next.units) {
        final text = _assemble(unit);
        if (text != null) translations[unit.id] = text;
      }
    } on Object {
      if (_current(generation)) error = '无法读取已保存译文，请重试';
    } finally {
      if (_current(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> translateMissing() async {
    final currentSource = source;
    final currentPlan = plan;
    if (!canTranslate || currentSource == null || currentPlan == null) return;
    final generation = ++_generation;
    final token = AiCancelToken();
    _cancel = token;
    running = true;
    cancelled = false;
    error = null;
    notifyListeners();
    try {
      for (final pending in List.of(_unsaved.values)) {
        try {
          await repository.save(pending);
        } on Object {
          if (_current(generation)) error = '译文已获取但保存失败；重试将先保存，不会重复请求此片段';
          return;
        }
        if (!_current(generation)) return;
        _unsaved.remove(pending.unitId);
        _forgetPending(pending);
        saved = [...saved, pending];
      }
      for (final unit in currentSource.units) {
        if (!_current(generation) || token.isCancelled) return;
        if (translations.containsKey(unit.id)) continue;
        final output = StringBuffer();
        for (final piece in translationWorkItems(unit)) {
          if (piece.protected) {
            output.write(piece.text);
            continue;
          }
          final cached = _received[piece.id];
          if (cached != null && cached.original == piece.text) {
            output.write(cached.translated);
            continue;
          }
          if (token.isCancelled || !_current(generation)) return;
          final trimmed = piece.text.trim();
          final start = piece.text.indexOf(trimmed);
          final result = await service.translateWithPlan(
            currentPlan,
            text: trimmed,
            cancelToken: token,
          );
          if (token.isCancelled || !_current(generation)) return;
          final translated =
              '${piece.text.substring(0, start)}${result.text.trim()}${piece.text.substring(start + trimmed.length)}';
          final translation = SavedReadingTranslation(
            id: const Uuid().v4(),
            bookId: currentSource.bookId,
            sourceKey: currentSource.key,
            unitId: piece.id,
            original: piece.text,
            translated: translated,
            profileId: currentPlan.profile.id,
            profileLabel: currentPlan.profile.name,
            fingerprint: currentPlan.fingerprint,
            targetLanguage: currentPlan.profile.targetLanguage,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );
          output.write(translated);
          _received[piece.id] = translation;
          _unsaved[piece.id] = translation;
          final assembled = _assemble(unit);
          if (assembled != null) translations[unit.id] = assembled;
          notifyListeners();
          try {
            await repository.save(translation);
          } on Object {
            if (_current(generation)) error = '译文已获取但保存失败；重试将先保存，不会重复请求此片段';
            return;
          }
          if (!_current(generation)) return;
          _unsaved.remove(piece.id);
          _forgetPending(translation);
          saved = [...saved, translation];
          notifyListeners();
        }
        translations[unit.id] = output.toString();
        notifyListeners();
      }
    } on TranslationException catch (failure) {
      if (_current(generation) && !token.isCancelled) error = failure.message;
    } on Object {
      if (_current(generation) && !token.isCancelled) {
        error = '翻译未完成，请检查服务配置后重试；已保存的段落会保留';
      }
    } finally {
      if (_current(generation)) {
        running = false;
        _cancel = null;
        notifyListeners();
      }
    }
  }

  String? _assemble(ReadingTranslationUnit unit) {
    final output = StringBuffer();
    for (final piece in translationWorkItems(unit)) {
      if (piece.protected) {
        output.write(piece.text);
        continue;
      }
      final cached = _received[piece.id];
      if (cached == null || cached.original != piece.text) return null;
      output.write(cached.translated);
    }
    return output.toString();
  }

  void _forgetPending(SavedReadingTranslation translation) {
    final key = '${translation.bookId}|${translation.sourceKey}';
    _pendingSources[key]?.removeWhere((row) => row.id == translation.id);
    if (_pendingSources[key]?.isEmpty == true) _pendingSources.remove(key);
  }

  void cancel({bool notify = true}) {
    _cancel?.cancel();
    _cancel = null;
    _generation++;
    cancelled = running;
    running = false;
    if (notify && !_disposed) notifyListeners();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    _disposed = true;
    cancel(notify: false);
    super.dispose();
  }
}
