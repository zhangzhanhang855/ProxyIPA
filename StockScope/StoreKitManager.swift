import Foundation
import StoreKit

@objc public class StoreKitManager: NSObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    public static let shared = StoreKitManager()

    // 替换为你在 App Store Connect 中配置的非消耗型商品 ID
    "productID" = "com.example.stockscope.aipro"
    private var proProduct: SKProduct?
    private let kIsProUnlockedKey = "com.stockscope.iap.isProUnlocked"

    public var onPurchaseStatusChanged: ((Bool) -> Void)?

    private override init() {
        super.init()
        SKPaymentQueue.default().add(self)
        fetchProduct()
    }

    /// 查询本地是否已解锁
    public var isProUnlocked: Bool {
        return UserDefaults.standard.bool(forKey: kIsProUnlockedKey)
    }

    /// 向 App Store 请求商品信息
    public func fetchProduct() {
        let request = SKProductsRequest(productIdentifiers: Set([proProductID]))
        request.delegate = self
        request.start()
    }

    public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        if let product = response.products.first {
            self.proProduct = product
            print("[IAP] 成功加载商品: \(product.localizedTitle), 价格: \(product.price)")
        } else {
            print("[IAP] 未找到对应的商品 ID，请检查 App Store Connect 或 StoreKit Configuration 配置")
        }
    }

    /// 发起购买
    public func purchasePro() {
        guard let product = proProduct else {
            // 离线测试兜底：如果没有真机 StoreKit 配置，可在此提供模拟
            print("[IAP] 商品尚未准备就绪，重新发起请求")
            fetchProduct()
            return
        }
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }

    /// 恢复购买（苹果审核必备要求）
    public func restorePurchases() {
        SKPaymentQueue.default().restoreCompletedTransactions()
    }

    // MARK: - 交易队列监听
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased, .restored:
                UserDefaults.standard.set(true, forKey: kIsProUnlockedKey)
                SKPaymentQueue.default().finishTransaction(transaction)
                DispatchQueue.main.async { [weak self] in
                    self?.onPurchaseStatusChanged?(true)
                }
            case .failed:
                if let error = transaction.error as? SKError, error.code != .paymentCancelled {
                    print("[IAP] 购买失败: \(error.localizedDescription)")
                }
                SKPaymentQueue.default().finishTransaction(transaction)
            case .purchasing, .deferred:
                break
            @unknown default:
                break
            }
        }
    }
}
