import UIKit
import WebKit

class ViewController: UIViewController, WKScriptMessageHandler {
    var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        let contentController = WKUserContentController()
        contentController.add(self, name: "jrNativeBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Allow cross-origin local file execution for Pyodide assets
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let url = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "jrNativeBridge",
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else {
            return
        }

        let data = dict["data"] as? [String: Any] ?? [:]

        switch action {
        case "shutdown":
            // Graceful exit / terminate iOS application
            DispatchQueue.main.async {
                UIControl().sendAction(#selector(NSXPCConnection.suspend), to: UIApplication.shared, for: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    exit(0)
                }
            }

        case "getDeviceInfo":
            UIDevice.current.isBatteryMonitoringEnabled = true
            let dev = UIDevice.current

            let batteryLvl = dev.batteryLevel >= 0 ? "\(Int(dev.batteryLevel * 100))%" : "Unknown"
            let batteryState: String
            switch dev.batteryState {
            case .charging: batteryState = "Charging"
            case .full: batteryState = "Full"
            case .unplugged: batteryState = "Unplugged"
            default: batteryState = "Unknown"
            }

            var freeDisk = "Unknown"
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let free = attrs[.systemFreeSize] as? Int64 {
                freeDisk = String(format: "%.2f GB", Double(free) / 1_073_741_824.0)
            }

            let response: [String: String] = [
                "Device Model": dev.model,
                "System Name": dev.systemName,
                "OS Version": dev.systemVersion,
                "Device Name": dev.name,
                "Identifier": dev.identifierForVendor?.uuidString ?? "N/A",
                "Battery Level": batteryLvl,
                "Battery State": batteryState,
                "Available Storage": freeDisk,
                "Thermal State": "\(ProcessInfo.processInfo.thermalState.rawValue)"
            ]
            sendToJS(payload: response)

        case "hapticFeedback":
            let style = data["style"] as? String ?? "medium"
            DispatchQueue.main.async {
                let generator: UIImpactFeedbackGenerator
                switch style {
                case "heavy": generator = UIImpactFeedbackGenerator(style: .heavy)
                case "light": generator = UIImpactFeedbackGenerator(style: .light)
                default: generator = UIImpactFeedbackGenerator(style: .medium)
                }
                generator.impactOccurred()
            }
            sendToJS(payload: ["status": "ok"])

        case "setClipboard":
            if let text = data["text"] as? String {
                UIPasteboard.general.string = text
            }
            sendToJS(payload: ["status": "ok"])

        case "getClipboard":
            let clip = UIPasteboard.general.string ?? ""
            sendToJS(payload: ["text": clip])

        default:
            sendToJS(payload: ["error": "Unknown native action: \(action)"])
        }
    }

    private func sendToJS(payload: Any) {
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: json, encoding: .utf8) {
            let script = "window.onNativeBridgeResponse(\(jsonString));"
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }
}
