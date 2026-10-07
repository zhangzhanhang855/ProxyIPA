import UIKit
import WebKit
import GoogleSignIn // 需引入 GoogleSignIn 库

class WebViewController: UIViewController, WKScriptMessageHandler {
    var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        // 关键：注册 nativeGoogleLogin 供前端调用
        config.userContentController.add(self, name: "nativeGoogleLogin")

        webView = WKWebView(frame: view.bounds, configuration: config)
        view.addSubview(webView)

        // 加载你的本地 html
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // 关键：接收到前端点击事件
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeGoogleLogin" {
            // 唤起原生 Google 登录
            GIDSignIn.sharedInstance.signIn(withPresenting: self) { result, error in
                guard error == nil, let user = result?.user, let idToken = user.idToken?.tokenString else {
                    print("Google Sign-In failed: \(error?.localizedDescription ?? "")")
                    return
                }
                // 把拿到的 idToken 传回给 HTML
                let js = "window.handleNativeGoogleAuth('\(idToken)')"
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}
