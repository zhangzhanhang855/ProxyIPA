import UIKit
import WebKit

class ViewController: UIViewController, WKScriptMessageHandler {
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        EnvironmentDetector.shared.startMonitoring()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "getEnvironmentSnapshot")
        config.userContentController = userContent

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        // 加载本地打包的 index.html
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        } else {
            print("[StockScope] 找不到 index.html 文件")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "getEnvironmentSnapshot" {
            let payload = EnvironmentDetector.shared.evaluateCurrentEnvironment()
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let js = "if(window.onEnvironmentUpdate){ window.onEnvironmentUpdate(\(jsonString)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}
