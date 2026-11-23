import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/database_providers.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/ai/ai_models.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/features/ai/application/ai_chat_service.dart';
import 'package:pagesage/features/ai/application/ai_providers.dart';
import 'package:pagesage/features/settings/application/ai_settings_form_controller.dart';
import 'package:pagesage/features/settings/application/ai_settings_providers.dart';

void main() {
  test(
    'a first-save failure adopts the created profile without dropping its draft',
    () async {
      final harness = await _Harness.create();
      harness.repository.createdProfileId = 'created-on-first-save';
      harness.repository.failSaves = 1;
      harness.controller.edit(AiSettingsField.model, 'draft-model');
      harness.controller.edit(AiSettingsField.apiKey, 'draft-secret');
      await harness.controller.save();
      expect(harness.state.saved?.activeProfileId, 'created-on-first-save');
      expect(harness.state.value(AiSettingsField.apiKey), 'draft-secret');
      await harness.controller.save();
      expect(
        harness.repository.saves.last.activeProfileId,
        'created-on-first-save',
      );
      expect(harness.repository.settings.model, 'draft-model');
    },
  );

  test('disabled AI can save drafts without enabling network access', () async {
    final harness = await _Harness.create();
    await harness.controller.setEnabled(false);
    harness.controller.edit(AiSettingsField.model, 'prepared-offline');
    await harness.controller.save();
    expect(harness.repository.settings.model, 'prepared-offline');
    expect(harness.repository.settings.enabled, isFalse);
    await harness.controller.save(testConnection: true);
    expect(harness.provider.tests, 0);
  });

  test(
    'slow saves exclude every competing mutation and connection test',
    () async {
      final harness = await _Harness.create();
      final gate = Completer<void>();
      harness.repository.saveGate = gate;
      harness.controller.edit(AiSettingsField.model, 'new-model');
      final pending = harness.controller.save();
      await harness.controller.save();
      await harness.controller.save(testConnection: true);
      await harness.controller.setEnabled(false);
      await harness.controller.clearApiKey();
      expect(harness.repository.saves, hasLength(1));
      expect(harness.provider.tests, 0);
      expect(harness.repository.clears, 0);
      expect(harness.state.operation, AiSettingsOperation.saving);
      gate.complete();
      await pending;
      expect(harness.repository.settings.model, 'new-model');
      expect(harness.state.isDirty, isFalse);
    },
  );

  test(
    'failed saves retain all input and the replacement key for retry',
    () async {
      final harness = await _Harness.create();
      harness.repository.failSaves = 1;
      harness.controller.edit(AiSettingsField.model, 'draft-model');
      harness.controller.edit(AiSettingsField.apiKey, 'test-replacement-key');
      await harness.controller.save();
      expect(harness.state.isBusy, isFalse);
      expect(harness.state.isDirty, isTrue);
      expect(
        harness.state.value(AiSettingsField.apiKey),
        'test-replacement-key',
      );
      expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.error);
      await harness.controller.save();
      expect(harness.repository.settings.model, 'draft-model');
      expect(harness.repository.keys.last, 'test-replacement-key');
      expect(harness.state.value(AiSettingsField.apiKey), isEmpty);
      expect(harness.state.isDirty, isFalse);
    },
  );

  test(
    'external updates merge untouched fields without losing drafts',
    () async {
      final harness = await _Harness.create();
      harness.controller.edit(AiSettingsField.model, 'draft-model');
      harness.controller.edit(AiSettingsField.apiKey, 'test-new-key');
      harness.controller.setStreaming(false);
      harness.repository.publish(
        harness.repository.settings.copyWith(
          model: 'external-model',
          baseUrl: 'https://other.example.test/v1',
          maxTokens: 2048,
        ),
      );
      await pumpEventQueue();
      expect(harness.state.value(AiSettingsField.model), 'draft-model');
      expect(harness.state.value(AiSettingsField.apiKey), 'test-new-key');
      expect(
        harness.state.value(AiSettingsField.baseUrl),
        'https://other.example.test/v1',
      );
      expect(harness.state.value(AiSettingsField.maxTokens), '2048');
      expect(harness.state.streaming, isFalse);
      expect(harness.state.saved?.model, 'external-model');
    },
  );

  test('the enabled switch persists only the saved configuration', () async {
    final harness = await _Harness.create();
    harness.controller.edit(AiSettingsField.model, 'draft-model');
    harness.controller.setStreaming(false);
    await harness.controller.setEnabled(false);
    await pumpEventQueue();
    expect(harness.repository.settings.enabled, isFalse);
    expect(harness.repository.settings.model, 'saved-model');
    expect(harness.repository.settings.streaming, isTrue);
    expect(harness.state.value(AiSettingsField.model), 'draft-model');
    expect(harness.state.streaming, isFalse);
    expect(harness.state.isDirty, isTrue);
  });

  test(
    'invalid fields block persistence and expose the advanced error',
    () async {
      final harness = await _Harness.create();
      harness.controller.edit(AiSettingsField.baseUrl, 'missing-scheme');
      harness.controller.edit(AiSettingsField.model, ' ');
      harness.controller.edit(AiSettingsField.temperature, 'NaN');
      harness.controller.edit(AiSettingsField.maxTokens, '0');
      await harness.controller.save(testConnection: true);
      expect(harness.repository.saves, isEmpty);
      expect(harness.provider.tests, 0);
      expect(harness.state.errors, hasLength(4));
      expect(harness.state.hasAdvancedErrors, isTrue);
    },
  );

  test(
    'testing waits for save completion and reports the saved configuration',
    () async {
      final harness = await _Harness.create();
      final saving = Completer<void>();
      final testing = Completer<AiProviderStatus>();
      harness.repository.saveGate = saving;
      harness.provider.gate = testing;
      harness.controller.edit(AiSettingsField.model, 'tested-model');
      final pending = harness.controller.save(testConnection: true);
      expect(harness.state.operation, AiSettingsOperation.savingForTest);
      expect(harness.provider.tests, 0);
      saving.complete();
      await pumpEventQueue();
      expect(harness.state.operation, AiSettingsOperation.testing);
      expect(harness.provider.models, ['tested-model']);
      await harness.controller.save();
      await harness.controller.clearApiKey();
      expect(harness.repository.saves, hasLength(1));
      expect(harness.repository.clears, 0);
      testing.complete(AiProviderStatus.ready);
      await pending;
      expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.success);
      expect(harness.state.isBusy, isFalse);
    },
  );

  test(
    'a failed test distinguishes saved settings from connection failure',
    () async {
      final harness = await _Harness.create();
      harness.provider.failure = const AiChatException('模型不可用');
      harness.controller.edit(AiSettingsField.model, 'unavailable-model');
      await harness.controller.save(testConnection: true);
      expect(harness.repository.settings.model, 'unavailable-model');
      expect(harness.state.isDirty, isFalse);
      expect(harness.state.feedback?.message, contains('配置已保存'));
      expect(harness.state.feedback?.message, contains('模型不可用'));
      expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.error);
      expect(harness.state.isBusy, isFalse);
    },
  );

  test(
    'an old test result cannot replace a newer configuration or test',
    () async {
      final harness = await _Harness.create();
      final oldTest = Completer<AiProviderStatus>();
      harness.provider.gate = oldTest;
      final first = harness.controller.save(testConnection: true);
      await pumpEventQueue();
      harness.repository.publish(
        harness.repository.settings.copyWith(model: 'new-model'),
      );
      await pumpEventQueue();
      expect(harness.state.feedback?.message, '连接配置已变更，请重新测试');
      expect(harness.state.isBusy, isFalse);
      final newTest = Completer<AiProviderStatus>();
      harness.provider.gate = newTest;
      final second = harness.controller.save(testConnection: true);
      await pumpEventQueue();
      oldTest.complete(AiProviderStatus.ready);
      await first;
      expect(harness.state.operation, AiSettingsOperation.testing);
      expect(harness.state.feedback, isNull);
      newTest.complete(AiProviderStatus.unavailable);
      await second;
      expect(harness.provider.models, ['saved-model', 'new-model']);
      expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.error);
    },
  );

  test('disposing the form ignores a pending test completion', () async {
    final harness = await _Harness.create();
    final gate = Completer<AiProviderStatus>();
    harness.provider.gate = gate;
    final pending = harness.controller.save(testConnection: true);
    await pumpEventQueue();
    await harness.close();
    gate.complete(AiProviderStatus.ready);
    await pending;
  });

  test('first profile save keeps the returned identity and tests it', () async {
    final harness = await _Harness.create();
    harness.repository.createdProfileId = 'created';
    harness.controller.edit(AiSettingsField.model, 'first-model');
    await harness.controller.save(testConnection: true);
    await pumpEventQueue();
    expect(harness.state.saved?.activeProfileId, 'created');
    expect(harness.state.isBusy, isFalse);
    expect(harness.provider.models, ['first-model']);
    expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.success);
  });

  test(
    'a save completing after a profile switch cannot replace the form',
    () async {
      final harness = await _Harness.create();
      final original = harness.repository.settings.copyWith(
        activeProfileId: 'a',
      );
      harness.repository.publish(original);
      await pumpEventQueue();
      final gate = Completer<void>();
      harness.repository.saveGate = gate;
      harness.repository.publishOnSave = false;
      harness.controller.edit(AiSettingsField.model, 'draft-a');
      final pending = harness.controller.save(testConnection: true);
      harness.repository.publish(
        original.copyWith(activeProfileId: 'b', model: 'model-b'),
      );
      await pumpEventQueue();
      gate.complete();
      await pending;
      expect(harness.state.saved?.activeProfileId, 'b');
      expect(harness.state.value(AiSettingsField.model), 'model-b');
      expect(harness.state.isBusy, isFalse);
      expect(harness.provider.tests, 0);
    },
  );

  test(
    'switching profiles ignores the old test and clears its busy draft',
    () async {
      final harness = await _Harness.create();
      final original = harness.repository.settings.copyWith(
        activeProfileId: 'a',
      );
      harness.repository.publish(original);
      await pumpEventQueue();
      final testing = Completer<AiProviderStatus>();
      harness.provider.gate = testing;
      final pending = harness.controller.save(testConnection: true);
      await pumpEventQueue();
      expect(harness.state.operation, AiSettingsOperation.testing);

      harness.repository.publish(original.copyWith(activeProfileId: 'b'));
      await pumpEventQueue();
      testing.complete(AiProviderStatus.ready);
      await pending;
      expect(harness.state.saved?.activeProfileId, 'b');
      expect(harness.state.feedback, isNull);

      harness.repository.publish(original);
      await pumpEventQueue();
      expect(harness.state.operation, AiSettingsOperation.idle);
      harness.controller.edit(AiSettingsField.model, 'editable-again');
      expect(harness.state.value(AiSettingsField.model), 'editable-again');
    },
  );

  test('clearing a key handles failure and retains unrelated drafts', () async {
    final harness = await _Harness.create();
    harness.controller.edit(AiSettingsField.model, 'draft-model');
    harness.repository.failClear = true;
    await harness.controller.clearApiKey();
    expect(harness.state.saved?.hasApiKey, isTrue);
    expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.error);
    harness.repository.failClear = false;
    await harness.controller.clearApiKey();
    await pumpEventQueue();
    expect(harness.state.saved?.hasApiKey, isFalse);
    expect(harness.state.value(AiSettingsField.model), 'draft-model');
    expect(harness.state.isBusy, isFalse);
  });

  test(
    'discard restores persisted values and clears replacement credentials',
    () async {
      final harness = await _Harness.create();
      harness.controller.edit(AiSettingsField.model, 'draft-model');
      harness.controller.edit(AiSettingsField.apiKey, 'test-unsaved-key');
      harness.controller.setStreaming(false);
      harness.controller.discardChanges();
      expect(harness.state.value(AiSettingsField.model), 'saved-model');
      expect(harness.state.value(AiSettingsField.apiKey), isEmpty);
      expect(harness.state.streaming, isTrue);
      expect(harness.state.isDirty, isFalse);
      expect(harness.repository.saves, isEmpty);
    },
  );

  test('each profile keeps its own unsaved draft', () async {
    final harness = await _Harness.create();
    harness.repository.settings = harness.repository.settings.copyWith(
      activeProfileId: 'profile-a',
      profileName: 'A',
      model: 'model-a',
    );
    harness.repository.publish(harness.repository.settings);
    await pumpEventQueue();

    harness.controller.edit(AiSettingsField.model, 'draft-a');
    harness.repository.settings = harness.repository.settings.copyWith(
      activeProfileId: 'profile-b',
      profileName: 'B',
      model: 'model-b',
      baseUrl: 'https://b.example.test/v1',
    );
    harness.repository.publish(harness.repository.settings);
    await pumpEventQueue();

    expect(harness.state.value(AiSettingsField.model), 'model-b');
    expect(harness.state.isDirty, isFalse);

    harness.controller.edit(AiSettingsField.model, 'draft-b');
    harness.repository.settings = harness.repository.settings.copyWith(
      activeProfileId: 'profile-a',
      profileName: 'A',
      model: 'model-a',
      baseUrl: 'https://example.test/v1',
    );
    harness.repository.publish(harness.repository.settings);
    await pumpEventQueue();

    expect(harness.state.value(AiSettingsField.model), 'draft-a');
    expect(harness.state.isDirty, isTrue);
  });

  test('fetching models saves them for the active profile', () async {
    final harness = await _Harness.create();
    harness.repository.settings = harness.repository.settings.copyWith(
      activeProfileId: 'profile-a',
      modelsUrl: 'https://example.test/custom/models',
    );
    harness.repository.publish(harness.repository.settings);
    await pumpEventQueue();

    await harness.controller.fetchModels();

    expect(
      harness.provider.lastCatalogSettings?.modelsUrl,
      'https://example.test/custom/models',
    );
    expect(harness.repository.models.map((model) => model.id), [
      'remote-model',
    ]);
    expect(harness.state.modelOptions.map((model) => model.id), [
      'remote-model',
    ]);
    expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.success);
    expect(harness.state.isBusy, isFalse);
  });

  test('manual model ids are saved and selected in the form', () async {
    final harness = await _Harness.create();
    harness.repository.settings = harness.repository.settings.copyWith(
      activeProfileId: 'profile-a',
    );
    harness.repository.publish(harness.repository.settings);
    await pumpEventQueue();

    await harness.controller.addModel(id: 'local-model', name: '本地模型');

    expect(harness.repository.models.single.id, 'local-model');
    expect(harness.repository.models.single.name, '本地模型');
    expect(harness.repository.models.single.source, 'manual');
    expect(harness.state.value(AiSettingsField.model), 'local-model');
    expect(harness.state.isDirty, isTrue);
    expect(harness.state.feedback?.kind, AiSettingsFeedbackKind.success);
  });

  test('fetching keeps manually added models and their labels', () async {
    final harness = await _Harness.create();
    harness.repository.settings = harness.repository.settings.copyWith(
      activeProfileId: 'profile-a',
    );
    harness.repository.models.add(
      const AiModelOption(id: 'local-model', name: '本地模型', source: 'manual'),
    );
    harness.repository.publish(harness.repository.settings);
    await pumpEventQueue();

    await harness.controller.fetchModels();

    final byId = {
      for (final model in harness.state.modelOptions) model.id: model,
    };
    expect(byId.keys, containsAll(['remote-model', 'local-model']));
    expect(byId['local-model']?.name, '本地模型');
    expect(byId['local-model']?.source, 'manual');
  });

  test('models URL override is optional but validated', () async {
    final harness = await _Harness.create();
    harness.controller.edit(AiSettingsField.modelsUrl, 'not-a-url');
    await harness.controller.save();
    expect(harness.state.errors[AiSettingsField.modelsUrl], isNotNull);
    expect(harness.repository.saves, isEmpty);

    harness.controller.edit(
      AiSettingsField.modelsUrl,
      'https://example.test/custom/models',
    );
    await harness.controller.save();
    expect(
      harness.repository.settings.modelsUrl,
      'https://example.test/custom/models',
    );
  });
}

final class _Harness {
  _Harness(this.container, this.repository, this.provider, this.subscription);

  final ProviderContainer container;
  final _SettingsRepository repository;
  final _ConnectionProvider provider;
  final ProviderSubscription<AiSettingsFormState> subscription;
  bool _closed = false;

  AiSettingsFormController get controller =>
      container.read(aiSettingsFormProvider.notifier);
  AiSettingsFormState get state => container.read(aiSettingsFormProvider);

  static Future<_Harness> create() async {
    final repository = _SettingsRepository();
    final provider = _ConnectionProvider();
    final container = ProviderContainer(
      overrides: [
        aiSettingsRepositoryProvider.overrideWithValue(repository),
        aiProfileRepositoryProvider.overrideWithValue(repository),
        aiChatServiceProvider.overrideWithValue(
          AiChatService(
            settingsRepository: repository,
            conversationRepository: _UnusedConversations(),
            secureStore: SecureStore(),
            provider: provider,
            readSecret: (_) async => 'test-key',
          ),
        ),
      ],
    );
    final subscription = container.listen(aiSettingsFormProvider, (_, next) {});
    await container.read(aiSettingsProvider.future);
    await pumpEventQueue();
    final harness = _Harness(container, repository, provider, subscription);
    addTearDown(harness.close);
    return harness;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    subscription.close();
    container.dispose();
    await repository.changes.close();
  }
}

final class _SettingsRepository
    implements AiSettingsRepository, AiProfileRepository {
  AiSettings settings = const AiSettings(
    enabled: true,
    baseUrl: 'https://example.test/v1',
    model: 'saved-model',
    hasApiKey: true,
  );
  final changes = StreamController<AiSettings>.broadcast();
  final saves = <AiSettings>[];
  final keys = <String?>[];
  final models = <AiModelOption>[];
  Completer<void>? saveGate;
  String? createdProfileId;
  bool publishOnSave = true;
  int failSaves = 0;
  bool failClear = false;
  int clears = 0;

  void publish(AiSettings settings) {
    this.settings = settings.copyWith(modelOptions: [...models]);
    changes.add(this.settings);
  }

  @override
  Future<AiSettings> getSettings() async =>
      settings.copyWith(modelOptions: [...models]);

  @override
  Stream<AiSettings> watchSettings() async* {
    yield settings.copyWith(modelOptions: [...models]);
    yield* changes.stream.map(
      (next) => next.copyWith(modelOptions: [...models]),
    );
  }

  @override
  Future<List<AiModelOption>> listModels(String profileId) async =>
      settings.activeProfileId == profileId ? [...models] : const [];

  @override
  Future<void> saveModels(String profileId, List<AiModelOption> saved) async {
    if (settings.activeProfileId != profileId) return;
    models
      ..clear()
      ..addAll(saved);
  }

  @override
  Future<List<AiProfile>> listProfiles() async => const [];

  @override
  Stream<List<AiProfile>> watchProfiles() => Stream.value(const []);

  @override
  Future<AiProfile?> getProfile(String id) async => null;

  @override
  Future<AiProfile> createProfile({
    required String name,
    String? sourceProfileId,
    bool copyCredential = false,
  }) => throw UnsupportedError('catalogue tests do not create profiles');

  @override
  Future<AiProfile> updateProfile(
    AiProfile profile, {
    String? apiKey,
    required int expectedRevision,
  }) => throw UnsupportedError('catalogue tests do not update profiles');

  @override
  Future<void> deleteProfile(String id, {String? replacementProfileId}) =>
      throw UnsupportedError('catalogue tests do not delete profiles');

  @override
  Future<void> setActiveProfile(String? id) async {}

  @override
  Future<void> saveSettings(AiSettings settings, {String? apiKey}) async {
    saves.add(settings);
    keys.add(apiKey);
    await saveGate?.future;
    if (failSaves > 0) {
      failSaves -= 1;
      if (createdProfileId != null && this.settings.activeProfileId == null) {
        this.settings = this.settings.copyWith(
          activeProfileId: createdProfileId,
        );
      }
      throw StateError('test save failure');
    }
    if (!publishOnSave) return;
    publish(
      settings.copyWith(
        activeProfileId: settings.activeProfileId ?? createdProfileId,
        hasApiKey: settings.hasApiKey || (apiKey?.isNotEmpty ?? false),
      ),
    );
  }

  @override
  Future<void> clearApiKey() async {
    clears += 1;
    if (failClear) throw StateError('test clear failure');
    publish(settings.copyWith(hasApiKey: false));
  }
}

final class _ConnectionProvider implements AiProvider, AiModelCatalogSource {
  Completer<AiProviderStatus>? gate;
  AiChatException? failure;
  int tests = 0;
  final models = <String>[];
  List<AiModelOption> catalog = const [
    AiModelOption(id: 'remote-model', name: 'Remote Model', source: 'remote'),
  ];
  AiSettings? lastCatalogSettings;

  @override
  Future<List<AiModelOption>> listModels({
    required AiSettings settings,
    required String apiKey,
    AiCancelToken? cancelToken,
  }) async {
    lastCatalogSettings = settings;
    return catalog;
  }

  @override
  Future<AiProviderStatus> testConnection({
    required AiSettings settings,
    required String apiKey,
    AiCancelToken? cancelToken,
  }) async {
    tests += 1;
    models.add(settings.model);
    final error = failure;
    if (error != null) throw error;
    return gate?.future ?? AiProviderStatus.ready;
  }

  @override
  Stream<AiChunk> streamChat({
    required AiRequest request,
    required String apiKey,
    AiCancelToken? cancelToken,
  }) => throw UnsupportedError('connection tests must not send book content');
}

final class _UnusedConversations implements AiConversationRepository {
  @override
  Future<void> clearAll() async {}

  @override
  Future<List<AiConversation>> getConversations() async => [];

  @override
  Stream<List<AiConversation>> watchConversations() => const Stream.empty();

  @override
  Future<void> linkNote({
    required String conversationId,
    required String noteId,
  }) async {}

  @override
  Future<AiConversation> saveConversation({
    String? id,
    String? bookId,
    ReadingLocator? locator,
    required String provider,
    required String model,
    required String prompt,
    String? contextText,
    required String answer,
    String? sourceText,
    String? threadId,
    AiContextSnapshot? contextSnapshot,
  }) => throw UnsupportedError('connection tests must not save conversations');
}
