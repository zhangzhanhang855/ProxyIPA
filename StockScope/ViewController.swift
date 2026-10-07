import UIKit
import WebKit
import AVFoundation
import AuthenticationServices
import CryptoKit

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, ASWebAuthenticationPresentationContextProviding {

    var webView: WKWebView!
    var authSession: ASWebAuthenticationSession?

    let googleClientID = "808147352261-93do7ovt86lo55dustq2gqodk9f53qe4.apps.googleusercontent.com"
    let redirectScheme = "com.googleusercontent.apps.808147352261-93do7ovt86lo55dustq2gqodk9f53qe4"
    
    // 临时保存本次认证生成的 PKCE 验证码
    private var currentCodeVerifier: String?

    override func loadView() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession configuration error: \(error)")
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptEnabled = true
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        config.userContentController.add(self, name: "nativeGoogleLogin")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeGoogleLogin" {
            startGoogleOAuthFlow()
        }
    }

    // =========================================================================
    // 标准 PKCE 授权流程（解决 400: unsupported_response_type）
    // =========================================================================
    private func startGoogleOAuthFlow() {
        let redirectURI = "\(redirectScheme):/oauth2callback"
        
        // 1. 生成 PKCE 验证码 (Verifier) 与 Challenge
        let codeVerifier = generateRandomString(length: 64)
        self.currentCodeVerifier = codeVerifier
        let codeChallenge = generateCodeChallenge(verifier: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: googleClientID),
            URLQueryItem(name: "response_type", value: "code"), // 关键修改：从 id_token 改为 code
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else { return }

        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callbackURL, error in
            if let error = error {
                print("ASWebAuthenticationSession error: \(error.localizedDescription)")
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems else { return }

            // 从回调 URL 中提取返回的 authorization code
            if let authCode = queryItems.first(where: { $0.name == "code" })?.value,
               let verifier = self?.currentCodeVerifier {
                DispatchQueue.main.async {
                    // 将 code 与 verifier 传回前端
                    let js = "window.handleNativeGoogleCode('\(authCode)', '\(verifier)')"
                    self?.webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }

    // PKCE 辅助算法
    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private func generateCodeChallenge(verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hashed = SHA256.hash(data: data)
        return Data(hashed)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window ?? UIWindow()
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nativeGoogleLogin")
    }
}
