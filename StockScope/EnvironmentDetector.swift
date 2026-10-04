import Foundation
import CoreMotion
import CoreLocation
import AVFoundation
import CoreBluetooth

@objc public class EnvironmentDetector: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    public static let shared = EnvironmentDetector()

    // 硬件传感器与服务
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var locationManager: CLLocationManager?
    private var audioEngine: AVAudioEngine?
    private var centralManager: CBCentralManager?

    // 遥测状态数据
    private var lastPressureTime: Date?
    private var lastAltitude: Double = 0.0
    private var verticalSpeed: Double = 0.0
    private var currentZAccel: Double = 0.0
    private var currentSPL: Float = 35.0
    private var gpsAccuracy: Double = -1.0

    // 蓝牙与局域网探测缓存
    private var bleDeviceMap: [UUID: Date] = [:] // 滑动窗口过滤过期设备
    private let bleLock = NSLock()
    private var currentBleCount: Int = 0
    private var currentLanDeviceCount: Int = 1   // 默认包含本机
    private var isLanScanning: Bool = false

    private override init() {
        super.init()
    }

    public func startMonitoring() {
        startMotionAndAltimeter()
        initLocationSafely()
        initAudioSafely()
        initBluetoothSafely()
        startLanScanLoop()
    }

    // 1. 初始化蓝牙 BLE 密集度扫描
    private func initBluetoothSafely() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .background))
        }

        // 定时清理超过 8 秒未活跃的外设，保证人流计数的动态真实性
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.bleLock.lock()
            let now = Date()
            self.bleDeviceMap = self.bleDeviceMap.filter { now.timeIntervalSince($0.value) < 8.0 }
            self.currentBleCount = self.bleDeviceMap.count
            self.bleLock.unlock()
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // 允许重复广播以维持实时密集度计算
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        bleLock.lock()
        bleDeviceMap[peripheral.identifier] = Date()
        bleLock.unlock()
    }

    // 2. 局域网 (LAN) 主机扫描器（探测当前子网在线活跃设备）
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

            var discoveredCount = 1 // 包含本机
            let group = DispatchGroup()
            let lock = NSLock()

            // 采样探测常用局域网段 IP（1~60段核心主机及网关）
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
        var clientSocket: Int32 = -1
        clientSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            completion(false)
            return
        }

        // 设置非阻塞
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

        // 超时监听
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
                if name == "en0" { // Wi-Fi 网卡
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

    // 3. 安全初始化运动、定位与音频
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

    private func initAudioSafely() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async {
                self?.setupAudioEngine()
            }
        }
    }

    private func setupAudioEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else { return }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = UInt(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<Int(frameLength) {
                    let val = channelData[i]
                    sum += val * val
                }
                let rms = sqrt(sum / Float(max(frameLength, 1)))
                let db = 20 * log10(max(rms, 0.0001)) + 100

                DispatchQueue.main.async {
                    self?.currentSPL = max(20.0, min(120.0, db))
                }
            }

            try engine.start()
            self.audioEngine = engine
        } catch {
            print("[StockScope] 音频引擎启动异常: \(error)")
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            self.gpsAccuracy = loc.horizontalAccuracy
        }
    }

    /// 导出全维度感知载荷
    public func evaluateCurrentEnvironment() -> [String: Any] {
        return [
            "environment": abs(verticalSpeed) >= 1.2 ? "电梯内 (Elevator)" : "监测中",
            "confidence": 0.88,
            "metrics": [
                "vertical_speed_m_s": String(format: "%.2f", verticalSpeed),
                "z_acceleration": String(format: "%.3f", currentZAccel),
                "sound_level_dba": String(format: "%.1f", currentSPL),
                "gps_accuracy_m": String(format: "%.1f", gpsAccuracy),
                "ble_devices_count": currentBleCount,
                "lan_devices_count": currentLanDeviceCount
            ]
        ]
    }
}

// 辅助扩展：fd_set 操作
extension fd_set {
    mutating func zero() {
        self = fd_set()
    }
    mutating func add(fd: Int32) {
        let intOffset = Int(fd / 32)
        let bitOffset = Int(fd % 32)
        let mask = Int32(1 << bitOffset)
        withUnsafeMutablePointer(to: &self.fds_bits) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
            rawPtr[intOffset] |= mask
        }
    }
}
