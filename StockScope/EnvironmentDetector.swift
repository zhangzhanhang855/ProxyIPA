import Foundation
import CoreMotion
import CoreLocation
import CoreBluetooth

@objc public class EnvironmentDetector: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    public static let shared = EnvironmentDetector()

    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var locationManager: CLLocationManager?
    private var centralManager: CBCentralManager?

    private var lastPressureTime: Date?
    private var lastAltitude: Double = 0.0
    private var verticalSpeed: Double = 0.0
    private var currentZAccel: Double = 0.0
    private var gpsAccuracy: Double = -1.0

    // 存储当前窗口内扫描到的设备：UUID -> (最后出现时间, 信号强度)
    private var bleDeviceMap: [String: (lastSeen: Date, rssi: Int)] = [:]
    private let bleLock = NSLock()
    private var currentLanDeviceCount: Int = 1
    private var isLanScanning: Bool = false

    private override init() {
        super.init()
    }

    public func startMonitoring() {
        startMotionAndAltimeter()
        initLocationSafely()
        initBluetoothSafely()
        startLanScanLoop()
    }

    private func initBluetoothSafely() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .background))
        }

        // 每 2 秒剔除超过 8 秒未活跃的外设
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

    private func startLanScanLoop() {
        Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            self?.performLanSweep()
        }
        performLanSweep()
    }

    private func performLanSweep() {
        guard !isLanScanning else { return }
        isLanScanning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let localIP = self.getLocalIPAddress() else {
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

            for i in 1...60 {
                let targetHost = "\(subnet).\(i)"
                group.enter()
                self.checkPortOpen(host: targetHost, port: 80, timeout: 0.15) { isOpen in
                    if isOpen {
                        lock.lock()
                        discoveredCount += 1
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.currentLanDeviceCount = discoveredCount
                self.isLanScanning = false
            }
        }
    }

    private func checkPortOpen(host: String, port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let clientSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            completion(false)
            return
        }

        let flags = fcntl(clientSocket, F_GETFL, 0)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            close(clientSocket)
            completion(true)
            return
        }

        var fdSet = fd_set()
        fdSet.zero()
        fdSet.add(fd: clientSocket)
        var tv = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(timeout * 1_000_000))

        let selectRes = select(clientSocket + 1, nil, &fdSet, nil, &tv)
        close(clientSocket)
        completion(selectRes > 0)
    }

    private func getLocalIPAddress() -> String? {
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

    /// 导出全量遥测数据，包含具体活跃的 BLE 设备 ID 列表
    public func evaluateCurrentEnvironment() -> [String: Any] {
        bleLock.lock()
        let bleList = bleDeviceMap.map { ["id": $0.key, "rssi": $0.value.rssi] }
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
