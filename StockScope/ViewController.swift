import UIKit
import WebKit

class ViewController: UIViewController, WKScriptMessageHandler {
    var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "getEnvironmentSnapshot")
        config.userContentController = userContentController

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        // 启动传感器
        EnvironmentDetector.shared.startMonitoring()

        // 正确加载本地 index.html
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        } else {
            print("[StockScope] 错误：未在 Bundle 根目录下找到 index.html")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "getEnvironmentSnapshot" {
            let envData = EnvironmentDetector.shared.evaluateCurrentEnvironment()
            if let jsonData = try? JSONSerialization.data(withJSONObject: envData),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let jsCallback = "if(window.onEnvironmentUpdate){window.onEnvironmentUpdate(\(jsonString));}"
                webView.evaluateJavaScript(jsCallback, completionHandler: nil)
            }
        }
    }
}
