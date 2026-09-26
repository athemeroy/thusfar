import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // A reading window: taller than wide, centred on first launch.
    self.setContentSize(NSSize(width: 1000, height: 780))
    self.minSize = NSSize(width: 420, height: 560)
    self.center()
    self.setFrameAutosaveName("ThusfarMain")

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
