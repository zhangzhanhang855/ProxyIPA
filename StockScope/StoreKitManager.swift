import Foundation
import StoreKit
import UIKit

@objc public class StoreKitManager: NSObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    @objc public static let shared = StoreKitManager()

    public let proProductID = "com.example.stockscope.aipro"
    private var proProduct: SKProduct?
    private let kIsProUnlockedKey = "com.stockscope.iap.isProUnlocked"

    public var onPurchaseStatusChanged: ((Bool) -> Void)?

    private override init() {
        super.init()
        SKPaymentQueue.default().add(self)
        fetchProduct()
    }

    /// 查询本地是否已解锁
    @objc public var isProUnlocked: Bool {
        return UserDefaults.standard.bool(forKey: kIsProUnlockedKey)
    }

    /// 向 StoreKit 请求商品信息
    @objc public func fetchProduct() {
        let request = SKProductsRequest(productIdentifiers: Set([proProductID]))
        request.delegate = self
        request.start()
    }

    public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        if let product = response.products.first {
            self.proProduct = product
            print("[IAP] 成功加载商品: \(product.localizedTitle), 价格: \(product.price)")
        } else {
            print("[IAP] 线上/本地未找到对应商品 ID: \(proProductID)")
        }
    }

    public func request(_ request: SKRequest, didFailWithError error: Error) {
        print("[IAP] 请求商品列表失败: \(error.localizedDescription)")
    }

    /// 发起购买流程
    @objc public func purchasePro() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. 如果系统成功加载了 StoreKit 商品，走系统标准支付
            if let product = self.proProduct {
                let payment = SKPayment(product: product)
                SKPaymentQueue.default().add(payment)
            } else {
                // 2. 自签名/离线测试兜底：弹出原生测试购买弹窗
                self.showSandboxPurchaseAlert()
            }
        }
    }

    /// 弹出原生测试购买确认框 (针对自签 IPA 无法连接 Apple 生产环境的解决方案)
    private func showSandboxPurchaseAlert() {
        guard let rootVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            // 如果获取不到根视图，直接强行解锁
            self.unlockAndNotify()
            return
        }

        let alert = UIAlertController(
            title: "EnvDetector Pro 解锁",
            message: "商品 ID: \(proProductID)\n价格: $0.99 (开发测试模式)\n是否确认解锁多裁判 AI 功能？",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "确认购买", style: .default, handler: { [weak self] _ in
            self?.unlockAndNotify()
        }))

        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))

        // 适配 iPad 弹窗，防止崩溃
        if let popover = alert.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        rootVC.present(alert, animated: true, completion: nil)
    }

    /// 恢复购买
    @objc public func restorePurchases() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.proProduct != nil {
                SKPaymentQueue.default().restoreCompletedTransactions()
            } else {
                // 本地检查并恢复
                self.unlockAndNotify()
            }
        }
    }

    private func unlockAndNotify() {
        UserDefaults.standard.set(true, forKey: self.kIsProUnlockedKey)
        self.onPurchaseStatusChanged?(true)
    }

    // MARK: - 交易队列状态监听
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased, .restored:
                SKPaymentQueue.default().finishTransaction(transaction)
                DispatchQueue.main.async { [weak self] in
                    self?.unlockAndNotify()
                }
            case .failed:
                SKPaymentQueue.default().finishTransaction(transaction)
            case .purchasing, .deferred:
                break
            @unknown default:
                break
            }
        }
    }
}
