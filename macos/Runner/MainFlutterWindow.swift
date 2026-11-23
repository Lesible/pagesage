import Cocoa
import FlutterMacOS

/// Hosts the Flutter view and receives Finder file drops for the library.
///
/// Registering the window for `.fileURL` makes it the dragging destination;
/// implementing `NSDraggingDestination` on the window keeps the drop entry
/// point independent of the Flutter view's mouse handling.
class MainFlutterWindow: NSWindow, NSDraggingDestination {
  private var dropChannel: FlutterMethodChannel?
  private var dropEnabled = false
  #if DEBUG
    private var dropVerificationChannel: FlutterMethodChannel?
  #endif

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "PageSage"
    self.minSize = NSSize(width: 960, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let messenger = flutterViewController.engine.binaryMessenger
    MacOSBookmarkChannel.register(with: messenger)
    PagesagePdfRasterChannel.register(with: messenger)
    PagesageOcrChannel.register(with: messenger)

    dropChannel = FlutterMethodChannel(
      name: "pagesage/window_drop",
      binaryMessenger: messenger
    )
    dropChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setEnabled" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.dropEnabled = call.arguments as? Bool ?? false
      result(nil)
    }
    registerForDraggedTypes([.fileURL])
    #if DEBUG
      registerDropVerificationChannel(with: messenger)
    #endif

    super.awakeFromNib()
  }

  // MARK: - NSDraggingDestination

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard dropEnabled, !droppedFileURLs(sender).isEmpty else {
      return []
    }
    dropChannel?.invokeMethod("dragEntered", arguments: nil)
    return .copy
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return dropEnabled && !droppedFileURLs(sender).isEmpty ? .copy : []
  }

  func draggingExited(_ sender: NSDraggingInfo?) {
    dropChannel?.invokeMethod("dragExited", arguments: nil)
  }

  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return dropEnabled && !droppedFileURLs(sender).isEmpty
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedFileURLs(sender).map(\.path)
    guard dropEnabled, !paths.isEmpty else {
      return false
    }
    dropChannel?.invokeMethod("filesDropped", arguments: paths)
    return true
  }

  private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    return sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: options
    ) as? [URL] ?? []
  }

  #if DEBUG
    /// Debug-only hook so integration tests can drive the real drop entry
    /// point without synthesizing OS-level drag events (which need
    /// Accessibility permission). Release builds do not expose it.
    private func registerDropVerificationChannel(
      with messenger: FlutterBinaryMessenger
    ) {
      let channel = FlutterMethodChannel(
        name: "pagesage/test_drop",
        binaryMessenger: messenger
      )
      dropVerificationChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "dropFile" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let self else {
          result(FlutterError(
            code: "unavailable",
            message: "window is gone",
            details: nil
          ))
          return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        guard let path = args["path"] as? String, !path.isEmpty else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "missing path",
            details: nil
          ))
          return
        }
        guard FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(
            code: "file_not_found",
            message: path,
            details: nil
          ))
          return
        }
        let pasteboard = NSPasteboard(
          name: NSPasteboard.Name("dev.pagesage.test.drag")
        )
        pasteboard.clearContents()
        guard pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        else {
          result(FlutterError(
            code: "drop_failed",
            message: "could not stage the dragged file",
            details: nil
          ))
          return
        }
        result(self.performDragOperation(
          PagesageMockDraggingInfo(pasteboard: pasteboard)
        ))
      }
    }
  #endif
}

#if DEBUG
  /// Minimal `NSDraggingInfo` backed by a real pasteboard. AppKit supplies the
  /// real object when a user drags; this only exists for the debug hook.
  private final class PagesageMockDraggingInfo: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
      self.pasteboard = pasteboard
      super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    func enumerateDraggingItems(
      options enumOpts: NSDraggingItemEnumerationOptions = [],
      for view: NSView?,
      classes classArray: [AnyClass],
      searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
      using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
  }
#endif

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
