import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../files/app_paths.dart';

/// A resolved security-scoped bookmark.
final class MacOSBookmarkResolution {
  const MacOSBookmarkResolution({required this.path, required this.bookmark});

  final String path;
  final String bookmark;
}

/// Native half of the macOS folder-access grant.
abstract interface class MacOSBookmarkChannel {
  Future<String> createBookmark(String path);

  Future<MacOSBookmarkResolution> resolveBookmark(String bookmark);

  Future<void> forget(String path);
}

final class MethodChannelMacOSBookmarkChannel implements MacOSBookmarkChannel {
  MethodChannelMacOSBookmarkChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pagesage/macos_bookmarks');

  final MethodChannel _channel;

  @override
  Future<String> createBookmark(String path) async {
    final bookmark = await _channel.invokeMethod<String>('create', {
      'path': path,
    });
    if (bookmark == null || bookmark.isEmpty) {
      throw const MacOSBookmarkException('无法保存文件夹访问授权');
    }
    return bookmark;
  }

  @override
  Future<MacOSBookmarkResolution> resolveBookmark(String bookmark) async {
    final result = await _channel.invokeMethod<dynamic>('resolve', {
      'bookmark': bookmark,
    });
    if (result is! Map) {
      throw const MacOSBookmarkException('文件夹访问授权返回格式无效');
    }
    final map = Map<Object?, Object?>.from(result);
    final path = (map['path'] as String?)?.trim();
    final resolved = (map['bookmark'] as String?)?.trim();
    if (path == null || path.isEmpty || resolved == null || resolved.isEmpty) {
      throw const MacOSBookmarkException('文件夹访问授权返回格式无效');
    }
    return MacOSBookmarkResolution(path: path, bookmark: resolved);
  }

  @override
  Future<void> forget(String path) {
    return _channel.invokeMethod<void>('forget', {'path': path});
  }
}

final class MacOSBookmarkException implements Exception {
  const MacOSBookmarkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Keeps read-in-place Markdown folders reachable across app launches.
///
/// A folder book is never copied into the library. Under App Sandbox the
/// open panel only grants access to the current process, so the bookmark is
/// stored next to the app data and resolved before any book is opened.
final class MacOSFolderAccess {
  MacOSFolderAccess({
    AppPaths? appPaths,
    MacOSBookmarkChannel? channel,
    bool? isMacOS,
    bool? isIOS,
  }) : _appPaths = appPaths ?? AppPaths(),
       _channel =
           channel ??
           MethodChannelMacOSBookmarkChannel(
             channel: (isIOS ?? Platform.isIOS)
                 ? const MethodChannel('pagesage/ios_bookmarks')
                 : null,
           ),
       _isEnabled = (isMacOS ?? Platform.isMacOS) || (isIOS ?? Platform.isIOS),
       _isIOS = isIOS ?? Platform.isIOS;

  final AppPaths _appPaths;
  final MacOSBookmarkChannel _channel;
  final bool _isEnabled;
  final bool _isIOS;
  final Set<String> _activePaths = <String>{};

  Future<File> _storeFile() async {
    final root = await _appPaths.dataRoot();
    return File(
      p.join(root.path, _isIOS ? 'ios-bookmarks.json' : 'macos-bookmarks.json'),
    );
  }

  Future<Map<String, String>> _readStore() async {
    final file = await _storeFile();
    if (!await file.exists()) {
      return <String, String>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['bookmarks'] is! Map) {
        return <String, String>{};
      }
      final bookmarks = <String, String>{};
      for (final entry in (decoded['bookmarks'] as Map).entries) {
        final path = entry.key;
        final bookmark = entry.value;
        if (path is String &&
            path.isNotEmpty &&
            bookmark is String &&
            bookmark.isNotEmpty) {
          bookmarks[path] = bookmark;
        }
      }
      return bookmarks;
    } on Object catch (error) {
      debugPrint('无法读取文件夹授权：$error');
      return <String, String>{};
    }
  }

  Future<void> _writeStore(Map<String, String> bookmarks) async {
    final file = await _storeFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'bookmarks': bookmarks}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  /// Saves the security-scoped grant for a folder picked by the user.
  ///
  /// Failing to persist the grant must not block importing the folder right
  /// now; the current session still has access from the open panel.
  Future<bool> remember(String folderPath) async {
    if (!_isEnabled) {
      return false;
    }
    final path = p.normalize(p.absolute(folderPath));
    try {
      final bookmark = await _channel.createBookmark(path);
      final bookmarks = await _readStore();
      bookmarks[path] = bookmark;
      await _writeStore(bookmarks);
      _activePaths.add(path);
      return true;
    } on Object catch (error) {
      debugPrint('无法保存文件夹授权：$error');
      return false;
    }
  }

  /// Resolves every stored bookmark and starts access for this launch.
  ///
  /// Stale bookmarks are replaced with a fresh grant. A missing or denied
  /// folder is left in the store so a later launch can retry after the writer
  /// restores it; the book itself reports the read failure.
  Future<void> restoreAll() async {
    if (!_isEnabled) {
      return;
    }
    final bookmarks = await _readStore();
    if (bookmarks.isEmpty) {
      return;
    }
    var changed = false;
    final resolved = <String, String>{};
    for (final entry in bookmarks.entries) {
      try {
        final resolution = await _channel.resolveBookmark(entry.value);
        resolved[resolution.path] = resolution.bookmark;
        _activePaths.add(resolution.path);
        if (resolution.path != entry.key ||
            resolution.bookmark != entry.value) {
          changed = true;
        }
      } on Object catch (error) {
        debugPrint('无法恢复文件夹授权：$error');
        resolved[entry.key] = entry.value;
      }
    }
    if (changed || resolved.length != bookmarks.length) {
      await _writeStore(resolved);
    }
  }

  /// Removes the grant when the folder book is removed from the library.
  Future<void> forget(String folderPath) async {
    if (!_isEnabled) {
      return;
    }
    final path = p.normalize(p.absolute(folderPath));
    final bookmarks = await _readStore();
    final hadBookmark = bookmarks.remove(path) != null;
    final wasActive = _activePaths.remove(path);
    if (!hadBookmark && !wasActive) {
      return;
    }
    try {
      await _channel.forget(path);
    } on Object catch (error) {
      debugPrint('无法停止文件夹授权：$error');
    }
    try {
      await _writeStore(bookmarks);
    } on Object catch (error) {
      // Removing the book must succeed even if the stale grant cannot be
      // rewritten; the next restore attempt simply retries it.
      debugPrint('无法更新文件夹授权记录：$error');
    }
  }

  @visibleForTesting
  Set<String> get activePaths => Set.unmodifiable(_activePaths);
}
