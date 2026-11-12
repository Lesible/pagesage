import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/files/app_paths.dart';
import 'package:pagesage/core/platform/macos_folder_access.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late AppPaths appPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pagesage_macos_access_');
    appPaths = AppPaths(overrideRoot: tempDir);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<Map<String, String>> readStore() async {
    final file = File(p.join(tempDir.path, 'macos-bookmarks.json'));
    if (!await file.exists()) {
      return <String, String>{};
    }
    final decoded = jsonDecode(await file.readAsString()) as Map;
    return Map<String, String>.from(decoded['bookmarks'] as Map);
  }

  test('remember persists a bookmark for a picked folder', () async {
    final channel = _FakeBookmarkChannel();
    final access = MacOSFolderAccess(
      appPaths: appPaths,
      channel: channel,
      isMacOS: true,
    );

    expect(await access.remember(tempDir.path), isTrue);

    final path = p.normalize(p.absolute(tempDir.path));
    expect(channel.created, [path]);
    expect(await readStore(), {path: 'bookmark:$path'});
  });

  test('restoreAll resolves bookmarks and reuses the stored grant', () async {
    final path = p.normalize(p.absolute(tempDir.path));
    final channel = _FakeBookmarkChannel()
      ..resolutions[path] = MacOSBookmarkResolution(
        path: path,
        bookmark: 'fresh',
      );
    final access = MacOSFolderAccess(
      appPaths: appPaths,
      channel: channel,
      isMacOS: true,
    );
    await access.remember(tempDir.path);

    final resumed = MacOSFolderAccess(
      appPaths: appPaths,
      channel: channel,
      isMacOS: true,
    );
    await resumed.restoreAll();

    expect(channel.resolved, ['bookmark:$path']);
    expect(resumed.activePaths, {path});
    expect(await readStore(), {path: 'fresh'});
  });

  test(
    'restoreAll keeps a bookmark when the folder cannot be resolved',
    () async {
      final path = p.normalize(p.absolute(tempDir.path));
      final channel = _FakeBookmarkChannel()..failures.add('bookmark:$path');
      final access = MacOSFolderAccess(
        appPaths: appPaths,
        channel: channel,
        isMacOS: true,
      );
      await access.remember(tempDir.path);

      final resumed = MacOSFolderAccess(
        appPaths: appPaths,
        channel: channel,
        isMacOS: true,
      );
      await resumed.restoreAll();

      expect(resumed.activePaths, isEmpty);
      expect(await readStore(), {path: 'bookmark:$path'});
    },
  );

  test('forget removes the store entry and stops native access', () async {
    final path = p.normalize(p.absolute(tempDir.path));
    final channel = _FakeBookmarkChannel();
    final access = MacOSFolderAccess(
      appPaths: appPaths,
      channel: channel,
      isMacOS: true,
    );
    await access.remember(tempDir.path);

    await access.forget(tempDir.path);

    expect(channel.forgotten, [path]);
    expect(await readStore(), isEmpty);
  });

  test('non-macOS platforms do not store grants', () async {
    final channel = _FakeBookmarkChannel();
    final access = MacOSFolderAccess(
      appPaths: appPaths,
      channel: channel,
      isMacOS: false,
    );

    expect(await access.remember(tempDir.path), isFalse);
    await access.restoreAll();
    await access.forget(tempDir.path);

    expect(channel.created, isEmpty);
    expect(await readStore(), isEmpty);
  });
}

final class _FakeBookmarkChannel implements MacOSBookmarkChannel {
  final created = <String>[];
  final resolved = <String>[];
  final forgotten = <String>[];
  final resolutions = <String, MacOSBookmarkResolution>{};
  final failures = <String>{};

  @override
  Future<String> createBookmark(String path) async {
    created.add(path);
    return 'bookmark:$path';
  }

  @override
  Future<MacOSBookmarkResolution> resolveBookmark(String bookmark) async {
    resolved.add(bookmark);
    if (failures.contains(bookmark)) {
      throw const MacOSBookmarkException('missing');
    }
    return resolutions[bookmark.substring('bookmark:'.length)] ??
        MacOSBookmarkResolution(
          path: bookmark.substring('bookmark:'.length),
          bookmark: bookmark,
        );
  }

  @override
  Future<void> forget(String path) async {
    forgotten.add(path);
  }
}
