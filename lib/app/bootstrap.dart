import 'package:flutter/foundation.dart';

import '../core/platform/macos_folder_access.dart';

Future<void> bootstrap() async {
  // A folder book is read in place; under the macOS sandbox the stored
  // security-scoped grant must be resolved before any reader or indexer opens
  // that folder. A grant failure must not prevent the app from starting:
  // the affected book will report the read failure instead.
  try {
    await MacOSFolderAccess().restoreAll();
  } on Object catch (error) {
    debugPrint('无法恢复 macOS 文件夹授权：$error');
  }
}
