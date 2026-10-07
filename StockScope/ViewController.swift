import UIKit
import WebKit
import AVFoundation
import AuthenticationServices

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, ASWebAuthenticationPresentationContextProviding {

    var webView: WKWebView!
    var authSession: ASWebAuthenticationSession?

    // 填入你在 Google Cloud 申请的 iOS 客户端 ID
    let googleClientID = "808147352261-93do7ovt86lo55dustq2gqodk9f53qe4.apps.googleusercontent.com"
    
    // 反向客户端 ID，用于 Google 登录完成后跳回 App
    // 格式为：将 Client ID 中的 .apps.googleusercontent.com 前缀逆转
    let redirectScheme = "com.googleusercontent.apps.808147352261-93do7ovt86lo55dustq2gqodk9f53qe4"

    override func loadView() {
        // 1. Enable background audio playback capabilities
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession configuration error: \(error)")
        }

        // 2. Configure WebKit behavior & JSBridge
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptEnabled = true
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // 注册桥接：监听前端发来的 "nativeGoogleLogin" 消息
        config.userContentController.add(self, name: "nativeGoogleLogin")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        
        // 3. UI refinements for a native app feel
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 4. Load bundled index.html
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // =========================================================================
    // MARK: - WKScriptMessageHandler (接收前端调用)
    // =========================================================================
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeGoogleLogin" {
            startGoogleOAuthFlow()
        }
    }

    // =========================================================================
    // MARK: - 原生 ASWebAuthenticationSession (拉起系统安全弹窗登录)
    // =========================================================================
    private func startGoogleOAuthFlow() {
        let redirectURI = "\(redirectScheme):/oauth2callback"
        let nonce = UUID().uuidString

        // 构造标准的 Google OAuth 授权请求 URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: googleClientID),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "nonce", value: nonce)
        ]

        guard let authURL = components.url else { return }

        // 使用系统原生验证组件拉起 Google 登录
        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callbackURL, error in
            if let error = error {
                print("ASWebAuthenticationSession error: \(error.localizedDescription)")
                return
            }

            guard let callbackURL = callbackURL else { return }

            // 从回调 URL 的 hash 片段中提取 id_token
            if let fragment = callbackURL.fragment {
                let params = fragment.components(separatedBy: "&").reduce(into: [String: String]()) { dict, item in
                    let pair = item.components(separatedBy: "=")
                    if pair.count == 2 {
                        dict[pair[0]] = pair[1]
                    }
                }

                if let idToken = params["id_token"] {
                    DispatchQueue.main.async {
                        // 将 Token 注入回 HTML 前端进行验签并存入 MongoDB
                        let js = "window.handleNativeGoogleAuth('\(idToken)')"
                        self?.webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }

    // =========================================================================
    // MARK: - ASWebAuthenticationPresentationContextProviding
    // =========================================================================
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window ?? UIWindow()
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nativeGoogleLogin")
    }
}
