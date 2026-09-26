import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 420, height: 560)
    // The view controller sizes the window to its own 800x600 later in
    // launch, so a default applied here is lost. Restore the reader's last
    // frame, or on first launch use a reading-sized window, after launch.
    let restored = self.setFrameUsingName("ThusfarMain")
    self.setFrameAutosaveName("ThusfarMain")
    if !restored {
      DispatchQueue.main.async {
        self.setContentSize(NSSize(width: 1000, height: 780))
        self.center()
      }
    }

    // The same bridge Android offers (thusfar/paths): incoming books and the
    // installed version. The data directory is resolved in Dart.
    let channel = FlutterMethodChannel(
      name: "thusfar/paths",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let delegate = NSApp.delegate as? AppDelegate
    delegate?.paths = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takeImports":
        result(delegate?.pendingImports ?? [])
        delegate?.pendingImports.removeAll()
      case "appVersion":
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        result("\(version) (\(build))")
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
