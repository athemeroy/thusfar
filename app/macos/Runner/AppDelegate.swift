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

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    for file in filenames {
      pendingImports.append([
        "name": (file as NSString).lastPathComponent,
        "path": file,
        "temporary": false,
      ])
    }
    paths?.invokeMethod("importsAvailable", arguments: nil)
    sender.reply(toOpenOrPrint: .success)
  }
}
