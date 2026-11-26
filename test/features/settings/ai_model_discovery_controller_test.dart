import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/features/ai/application/ai_model_catalog.dart';
import 'package:pagesage/features/settings/application/ai_settings_form_controller.dart';
import 'package:pagesage/features/settings/application/ai_settings_providers.dart';

void main() {
  late ProviderContainer container;
  late StreamController<AiSettings> settings;
  late _Catalog catalog;
  late ProviderSubscription<AiSettingsFormState> subscription;

  setUp(() async {
    settings = StreamController<AiSettings>();
    catalog = _Catalog();
    container = ProviderContainer(
      overrides: [
        aiSettingsProvider.overrideWith((ref) => settings.stream),
        aiModelCatalogProvider.overrideWithValue(catalog),
      ],
    );
    subscription = container.listen(aiSettingsFormProvider, (_, next) {});
    settings.add(
      const AiSettings(
        activeProfileId: 'one',
        baseUrl: 'https://example.test/v1',
        model: 'manual',
      ),
    );
    await pumpEventQueue();
  });
  tearDown(() async {
    subscription.close();
    container.dispose();
    await settings.close();
  });

  test(
    'discovery is independent of enabled flag and never overwrites manual model',
    () async {
      final controller = container.read(aiSettingsFormProvider.notifier);
      final pending = controller.fetchModels();
      expect(container.read(aiSettingsFormProvider).isBusy, isTrue);
      catalog.gate.complete(['discovered']);
      await pending;
      final state = container.read(aiSettingsFormProvider);
      expect(state.models, ['discovered']);
      expect(state.value(AiSettingsField.model), 'manual');
      expect(state.isBusy, isFalse);
      controller.edit(AiSettingsField.model, 'manually-typed');
      expect(
        container.read(aiSettingsFormProvider).value(AiSettingsField.model),
        'manually-typed',
      );
    },
  );

  test('late discovery response cannot overwrite another profile', () async {
    final controller = container.read(aiSettingsFormProvider.notifier);
    final pending = controller.fetchModels();
    settings.add(
      const AiSettings(
        activeProfileId: 'two',
        baseUrl: 'https://other.test/v1',
        model: 'second',
      ),
    );
    await pumpEventQueue();
    expect(catalog.token?.isCancelled, isTrue);
    catalog.gate.complete(['old-model']);
    await pending;
    final state = container.read(aiSettingsFormProvider);
    expect(state.saved?.activeProfileId, 'two');
    expect(state.models, isEmpty);
    expect(state.value(AiSettingsField.model), 'second');
    expect(state.isBusy, isFalse);
  });

  test('same-profile endpoint updates invalidate running discovery', () async {
    final controller = container.read(aiSettingsFormProvider.notifier);
    final pending = controller.fetchModels();
    settings.add(
      const AiSettings(
        activeProfileId: 'one',
        baseUrl: 'https://changed.test/v1',
        model: 'manual',
      ),
    );
    await pumpEventQueue();
    expect(catalog.token?.isCancelled, isTrue);
    catalog.gate.complete(['old-model']);
    await pending;
    expect(container.read(aiSettingsFormProvider).models, isEmpty);
    expect(container.read(aiSettingsFormProvider).isBusy, isFalse);
  });
}

final class _Catalog extends AiModelCatalog {
  _Catalog()
    : super(profiles: _UnusedProfiles(), secrets: SecureStore.memory());
  final gate = Completer<List<String>>();
  AiCancelToken? token;

  @override
  Future<List<String>> fetch({
    required String baseUrl,
    String apiKey = '',
    String? profileId,
    AiCancelToken? cancelToken,
  }) {
    token = cancelToken;
    return gate.future;
  }
}

final class _UnusedProfiles implements AiProfileRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Discovery fake must not access credentials');
}
