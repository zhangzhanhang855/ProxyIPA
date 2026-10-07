import UIKit
import WebKit
import AVFoundation
import AuthenticationServices
import CryptoKit

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, ASWebAuthenticationPresentationContextProviding {

    var webView: WKWebView!
    var authSession: ASWebAuthenticationSession?

    // Google iOS 客户端 ID
    let googleClientID = "808147352261-93do7ovt86lo55dustq2gqodk9f53qe4.apps.googleusercontent.com"
    let redirectScheme = "com.googleusercontent.apps.808147352261-93do7ovt86lo55dustq2gqodk9f53qe4"
    private var currentCodeVerifier: String?

    // 方案 2 线上托管地址
    let remoteAppURL = "https://music.aleafs.cn"

    override func loadView() {
        // 1. 配置后台音频播放会话
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession configuration error: \(error)")
        }

        // 2. 配置 WebKit 行为
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptEnabled = true

        // 注册桥接：Google 原生登录通道
        config.userContentController.add(self, name: "nativeGoogleLogin")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        
        // 3. 原生 App 视觉优化
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 4. 加载线上网页
        if let url = URL(string: remoteAppURL) {
            let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20.0)
            webView.load(request)
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // =========================================================================
    // MARK: - WKScriptMessageHandler
    // =========================================================================
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeGoogleLogin" {
            startGoogleOAuthFlow()
        }
    }

    private func startGoogleOAuthFlow() {
        let redirectURI = "\(redirectScheme):/oauth2callback"
        let codeVerifier = generateRandomString(length: 64)
        self.currentCodeVerifier = codeVerifier
        let codeChallenge = generateCodeChallenge(verifier: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: googleClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else { return }

        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callbackURL, error in
            if let error = error {
                print("Google Auth error: \(error.localizedDescription)")
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems else { return }

            if let authCode = queryItems.first(where: { $0.name == "code" })?.value,
               let verifier = self?.currentCodeVerifier {
                DispatchQueue.main.async {
                    let js = "window.handleNativeGoogleCode('\(authCode)', '\(verifier)')"
                    self?.webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }

    // =========================================================================
    // MARK: - 纯 Swift PKCE 算法 (不再使用 CommonCrypto，避免符号丢失)
    // =========================================================================
    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private func generateCodeChallenge(verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
