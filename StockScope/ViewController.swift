import UIKit
import WebKit

class ViewController: UIViewController, WKScriptMessageHandler {
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        EnvironmentDetector.shared.startMonitoring()

        // 监听内购变动，实时通知前端界面刷新
        StoreKitManager.shared.onPurchaseStatusChanged = { [weak self] isUnlocked in
            let js = "if(window.onPurchaseStateUpdate){ window.onPurchaseStateUpdate(\(isUnlocked)); }"
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "getEnvironmentSnapshot")
        userContent.add(self, name: "purchaseProFeature")
        userContent.add(self, name: "restoreProFeature")
        config.userContentController = userContent

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        } else {
            print("[EnvDetector] 找不到 index.html 文件")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "getEnvironmentSnapshot":
            var payload = EnvironmentDetector.shared.evaluateCurrentEnvironment()
            // 注入是否解锁 Pro 的标示
            payload["is_pro_unlocked"] = StoreKitManager.shared.isProUnlocked
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let js = "if(window.onEnvironmentUpdate){ window.onEnvironmentUpdate(\(jsonString)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        case "purchaseProFeature":
            StoreKitManager.shared.purchasePro()
        case "restoreProFeature":
            StoreKitManager.shared.restorePurchases()
        default:
            break
        }
    }
}
