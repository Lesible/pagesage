import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/translation/translation_models.dart';

void main() {
  const profile = TranslationProfile(
    id: 'test',
    name: '测试',
    provider: TranslationProvider.qwen,
    endpoint: 'https://example.test/v1',
    revision: 1,
  );

  test('new and historical profiles default to a one second interval', () {
    expect(profile.requestIntervalMs, 1000);
    final historical = profile.toJson()..remove('requestIntervalMs');
    expect(TranslationProfile.fromJson(historical).requestIntervalMs, 1000);
  });

  for (final interval in [0, 1, 1500, 60000]) {
    test('interval $interval survives JSON, language and storage copies', () {
      final updated = TranslationProfile.fromJson({
        ...profile.toJson(),
        'requestIntervalMs': interval,
      });
      expect(updated.requestIntervalMs, interval);
      expect(updated.withTargetLanguage('en').requestIntervalMs, interval);
      final saved = updated.withStorage(
        revision: 2,
        credentialRef: null,
        hasCredential: false,
      );
      expect(saved.requestIntervalMs, interval);
      expect(
        TranslationProfile.fromJson(saved.toJson()).requestIntervalMs,
        interval,
      );
    });
  }

  for (final invalid in <Object?>[null, '1000', 1000.0, -1, 60001, true]) {
    test(
      'invalid stored interval $invalid (${invalid.runtimeType}) is rejected',
      () {
        expect(
          () => TranslationProfile.fromJson({
            ...profile.toJson(),
            'requestIntervalMs': invalid,
          }),
          throwsFormatException,
        );
      },
    );
  }
}
