import UIKit
import WebKit

class ViewController: UIViewController, WKScriptMessageHandler {
    var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 启动传感器监控
        EnvironmentDetector.shared.startMonitoring()

        let contentController = WKUserContentController()
        contentController.add(self, name: "getEnvironmentSnapshot")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        webView = WKWebView(frame: view.bounds, configuration: config)
        view.addSubview(webView)

        if let url = URL(string: "http://localhost:3000") { // 或本地 index.html
            webView.load(URLRequest(url: url))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "getEnvironmentSnapshot" {
            let envData = EnvironmentDetector.shared.evaluateCurrentEnvironment()
            if let jsonData = try? JSONSerialization.data(withJSONObject: envData),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let jsCallback = "window.onEnvironmentUpdate(\(jsonString));"
                webView.evaluateJavaScript(jsCallback, completionHandler: nil)
            }
        }
    }
}
