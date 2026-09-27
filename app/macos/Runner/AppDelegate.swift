import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Books opened from Finder ("打开方式 → Thusfar") before Dart asks for them.
  /// They are the reader's own files, so Dart must not delete them after import.
  var pendingImports: [[String: Any]] = []
  var paths: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // FlutterAppDelegate implements application(_:open:), so AppKit delivers
  // Finder opens here rather than to application(_:openFiles:).
  override func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter { $0.isFileURL }
    for url in files {
      pendingImports.append([
        "name": url.lastPathComponent,
        "path": url.path,
        "temporary": false,
      ])
    }
    if !files.isEmpty {
      paths?.invokeMethod("importsAvailable", arguments: nil)
    }
    let others = urls.filter { !$0.isFileURL }
    if !others.isEmpty {
      super.application(application, open: others)
    }
  }
}
