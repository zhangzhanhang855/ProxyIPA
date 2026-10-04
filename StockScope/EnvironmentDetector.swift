import Foundation
import CoreMotion
import CoreLocation
import CoreBluetooth
import Network

@objc public class EnvironmentDetector: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    public static let shared = EnvironmentDetector()

    // 传感器组件
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var locationManager: CLLocationManager?
    private var centralManager: CBCentralManager?

    // 状态数据
    private var lastPressureTime: Date?
    private var lastAltitude: Double = 0.0
    private var verticalSpeed: Double = 0.0
    private var currentZAccel: Double = 0.0
    private var gpsAccuracy: Double = -1.0

    // BLE 扫描缓存（UUID 字符串映射时间与信号）
    private var bleDeviceMap: [String: (lastSeen: Date, rssi: Int)] = [:]
    private let bleLock = NSLock()
    
    // 网络探测状态
    private var currentLanDeviceCount: Int = 1
    private var isLanScanning: Bool = false
    private let lanQueue = DispatchQueue(label: "com.stockscope.lanQueue", qos: .utility)

    private override init() {
        super.init()
    }

    /// 统一启动入口
    public func startMonitoring() {
        startMotionAndAltimeter()
        initLocationSafely()
        initBluetoothSafely()
        startLanScanLoop()
    }

    // MARK: - 1. 蓝牙 BLE 扫描与去重 (无麦克风)
    private func initBluetoothSafely() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .background))
        }

        // 定期淘汰 8 秒未活跃的外设
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.bleLock.lock()
            let now = Date()
            self.bleDeviceMap = self.bleDeviceMap.filter { now.timeIntervalSince($0.value.lastSeen) < 8.0 }
            self.bleLock.unlock()
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        bleLock.lock()
        let id = peripheral.identifier.uuidString
        bleDeviceMap[id] = (lastSeen: Date(), rssi: RSSI.intValue)
        bleLock.unlock()
    }

    // MARK: - 2. 现代 Network.framework 局域网探测（彻底移除易错 C Socket）
    private func startLanScanLoop() {
        Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            self?.performModernLanSweep()
        }
        performModernLanSweep()
    }

    private func performModernLanSweep() {
        guard !isLanScanning else { return }
        isLanScanning = true

        lanQueue.async { [weak self] in
            guard let self = self else { return }
            guard let localIP = self.getWiFiAddress() else {
                self.isLanScanning = false
                return
            }

            let components = localIP.split(separator: ".")
            guard components.count == 4 else {
                self.isLanScanning = false
                return
            }
            let subnet = "\(components[0]).\(components[1]).\(components[2])"

            var discoveredCount = 1
            let group = DispatchGroup()
            let lock = NSLock()

            // 采样扫描前 40 个常用局域网主机 IP
            for i in 1...40 {
                let targetHost = "\(subnet).\(i)"
                group.enter()
                
                let host = NWEndpoint.Host(targetHost)
                let port = NWEndpoint.Port(integerLiteral: 80)
                let tcp = NWParameters.tcp
                tcp.prohibitedInterfaceTypes = [.cellular]
                
                let connection = NWConnection(host: host, port: port, using: tcp)
                let queue = DispatchQueue(label: "ping.\(targetHost)")

                var hasResponded = false
                connection.stateUpdateHandler = { state in
                    if hasResponded { return }
                    switch state {
                    case .ready, .waiting:
                        hasResponded = true
                        lock.lock()
                        discoveredCount += 1
                        lock.unlock()
                        connection.cancel()
                        group.leave()
                    case .failed:
                        hasResponded = true
                        connection.cancel()
                        group.leave()
                    default:
                        break
                    }
                }

                connection.start(queue: queue)

                // 250ms 超时强制回收连接，防止线程悬挂
                queue.asyncAfter(deadline: .now() + 0.25) {
                    if !hasResponded {
                        hasResponded = true
                        connection.cancel()
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                self.currentLanDeviceCount = discoveredCount
                self.isLanScanning = false
            }
        }
    }

    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }

    // MARK: - 3. 气压、加速度与 GNSS 定位
    private func startMotionAndAltimeter() {
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let self = self, let data = data, error == nil else { return }
                let currentAlt = data.relativeAltitude.doubleValue
                let now = Date()
                if let lastTime = self.lastPressureTime {
                    let dt = now.timeIntervalSince(lastTime)
                    if dt > 0.3 {
                        self.verticalSpeed = (currentAlt - self.lastAltitude) / dt
                        self.lastAltitude = currentAlt
                        self.lastPressureTime = now
                    }
                } else {
                    self.lastPressureTime = now
                    self.lastAltitude = currentAlt
                }
            }
        }

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.1
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self = self, let motion = motion else { return }
                self.currentZAccel = motion.userAcceleration.z
            }
        }
    }

    private func initLocationSafely() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.locationManager = CLLocationManager()
            self.locationManager?.delegate = self
            self.locationManager?.desiredAccuracy = kCLLocationAccuracyBest
            self.locationManager?.requestWhenInUseAuthorization()
            self.locationManager?.startUpdatingLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            self.gpsAccuracy = loc.horizontalAccuracy
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[StockScope] Location fail: \(error.localizedDescription)")
    }

    // MARK: - 4. 导出遥测数据供 JS 渲染
    public func evaluateCurrentEnvironment() -> [String: Any] {
        bleLock.lock()
        let bleList: [[String: Any]] = bleDeviceMap.map { [
            "id": $0.key,
            "rssi": $0.value.rssi
        ] }
        bleLock.unlock()

        return [
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "metrics": [
                "vertical_speed_m_s": String(format: "%.2f", verticalSpeed),
                "z_acceleration": String(format: "%.3f", currentZAccel),
                "gps_accuracy_m": String(format: "%.1f", gpsAccuracy),
                "lan_devices_count": currentLanDeviceCount,
                "ble_devices": bleList
            ]
        ]
    }
}
