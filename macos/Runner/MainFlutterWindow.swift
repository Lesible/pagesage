import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "PageSage"
    self.minSize = NSSize(width: 960, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacOSBookmarkChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Persists security-scoped access to folders the writer keeps outside the
/// app sandbox. Folder books are read in place, so the grant must survive a
/// relaunch instead of relying on the open panel that imported them.
private final class MacOSBookmarkChannel {
  private static let channelName = "pagesage/macos_bookmarks"
  private static var startedURLs: [String: URL] = [:]

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "create":
        guard let path = args?["path"] as? String else {
          result(FlutterError(code: "invalid_arguments", message: "missing path", details: nil))
          return
        }
        do {
          result(try createBookmark(path: path))
        } catch {
          result(FlutterError(code: "bookmark_create_failed", message: error.localizedDescription, details: nil))
        }
      case "resolve":
        guard let bookmark = args?["bookmark"] as? String else {
          result(FlutterError(code: "invalid_arguments", message: "missing bookmark", details: nil))
          return
        }
        do {
          result(try resolveBookmark(bookmark))
        } catch {
          result(FlutterError(code: "bookmark_resolve_failed", message: error.localizedDescription, details: nil))
        }
      case "forget":
        guard let path = args?["path"] as? String else {
          result(FlutterError(code: "invalid_arguments", message: "missing path", details: nil))
          return
        }
        forget(path: path)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func createBookmark(path: String) throws -> String {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let data = try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    return data.base64EncodedString()
  }

  private static func resolveBookmark(_ bookmark: String) throws -> [String: Any] {
    guard let data = Data(base64Encoded: bookmark) else {
      throw BookmarkError.invalidData
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw BookmarkError.missingPath
    }
    if startedURLs[url.path] == nil {
      guard url.startAccessingSecurityScopedResource() else {
        throw BookmarkError.accessDenied
      }
      startedURLs[url.path] = url
    }
    let resolved = stale ? try createBookmark(path: url.path) : bookmark
    return ["path": url.path, "bookmark": resolved]
  }

  private static func forget(path: String) {
    if let url = startedURLs.removeValue(forKey: path) {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private enum BookmarkError: LocalizedError {
    case invalidData
    case missingPath
    case accessDenied

    var errorDescription: String? {
      switch self {
      case .invalidData:
        return "invalid bookmark data"
      case .missingPath:
        return "bookmarked folder is missing"
      case .accessDenied:
        return "security-scoped access was denied"
      }
    }
  }
}
