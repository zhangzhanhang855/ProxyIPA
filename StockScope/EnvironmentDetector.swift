import Foundation
import CoreMotion
import CoreLocation
import CoreBluetooth
import Network

// MARK: - 数据模型：雷达上的单个外设节点
public struct RadarPeripheralNode {
    public let id: String
    public let rssi: Int
    public let estimatedDistanceMeters: Double
    public let bearingDegrees: Double
    public let rssiVariance: Double      // RSSI 方差/离散度
    public let sampleCount: Int
    public let isStaticCoMoving: Bool    // 是否属于长时间相对静止的同乘/车内设备
}

// MARK: - 微型 AI 裁判输出模型
public struct AIArbitrationResult {
    public let finalScore: Double        // 0 - 100 综合公共指数
    public let category: String          // 语义结论
    public let confidence: Double        // 0.0 - 1.0 置信度
    public let rationale: String         // AI 裁决推理陈词
    public let judgeScores: [String: Double] // 各裁判原始打分
    public let trimmedOutliers: [String] // 被裁减掉的极值裁判
}

@objc public class EnvironmentDetector: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    public static let shared = EnvironmentDetector()

    // 传感器组件
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var locationManager: CLLocationManager?
    private var centralManager: CBCentralManager?

    // 基础遥测指标
    private var lastPressureTime: Date?
    private var lastAltitude: Double = 0.0
    private var verticalSpeed: Double = 0.0
    private var currentZAccel: Double = 0.0
    private var gpsAccuracy: Double = -1.0
    private var currentHeadingDegrees: Double = 0.0

    // 蓝牙外设长周期追踪 (UUID -> 历史采样队列)
    private struct RSSIRecord {
        var rssiList: [(timestamp: Date, val: Int)]
        var lastSeen: Date
    }
    private var bleTelemetryMap: [String: RSSIRecord] = [:]
    private let bleLock = NSLock()

    // 网络探测
    private var currentLanDeviceCount: Int = 1
    private var isLanScanning: Bool = false
    private let lanQueue = DispatchQueue(label: "com.stockscope.lanQueue", qos: .utility)

    private override init() {
        super.init()
    }

    public func startMonitoring() {
        startMotionAndAltimeter()
        initLocationSafely()
        initBluetoothSafely()
        startLanScanLoop()
    }

    // MARK: - 1. 空间朝向与定位
    private func initLocationSafely() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.locationManager = CLLocationManager()
            self.locationManager?.delegate = self
            self.locationManager?.desiredAccuracy = kCLLocationAccuracyBest
            self.locationManager?.requestWhenInUseAuthorization()
            self.locationManager?.startUpdatingLocation()
            self.locationManager?.startUpdatingHeading() // 启动罗盘航向
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            self.gpsAccuracy = loc.horizontalAccuracy
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 {
            self.currentHeadingDegrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }

    // MARK: - 2. 气压与动力学
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

    // MARK: - 3. 蓝牙设备追踪与 RSSI 时间序列分析
    private func initBluetoothSafely() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .background))
        }

        // 定期维护滑动窗口：淘汰超时外设并限制历史队列在 15 秒内
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.bleLock.lock()
            let now = Date()
            var activeKeys: [String] = []

            for (uuid, record) in self.bleTelemetryMap {
                if now.timeIntervalSince(record.lastSeen) > 8.0 {
                    continue // 超时未刷新丢弃
                }
                // 保留 15 秒窗口内的数据
                let filteredList = record.rssiList.filter { now.timeIntervalSince($0.timestamp) <= 15.0 }
                if !filteredList.isEmpty {
                    self.bleTelemetryMap[uuid] = RSSIRecord(rssiList: filteredList, lastSeen: record.lastSeen)
                    activeKeys.append(uuid)
                }
            }

            self.bleTelemetryMap = self.bleTelemetryMap.filter { activeKeys.contains($0.key) }
            self.bleLock.unlock()
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuid = peripheral.identifier.uuidString
        let rawRssi = RSSI.intValue
        guard rawRssi < 0 && rawRssi > -110 else { return }

        bleLock.lock()
        var rec = bleTelemetryMap[uuid] ?? RSSIRecord(rssiList: [], lastSeen: Date())
        rec.rssiList.append((timestamp: Date(), val: rawRssi))
        if rec.rssiList.count > 25 { rec.rssiList.removeFirst() }
        rec.lastSeen = Date()
        bleTelemetryMap[uuid] = rec
        bleLock.unlock()
    }

    // MARK: - 4. 局域网活动扫描
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

            for i in 1...35 {
                let targetHost = "\(subnet).\(i)"
                group.enter()
                
                let host = NWEndpoint.Host(targetHost)
                let port = NWEndpoint.Port(integerLiteral: 80)
                let tcp = NWParameters.tcp
                tcp.prohibitedInterfaceTypes = [.cellular]
                
                let connection = NWConnection(host: host, port: port, using: tcp)
                let queue = DispatchQueue(label: "lan.\(targetHost)")

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

                queue.asyncAfter(deadline: .now() + 0.22) {
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

    // MARK: - 5. 雷达方位与距离解算
    private func computeRadarNodes() -> [RadarPeripheralNode] {
        bleLock.lock()
        defer { bleLock.unlock() }

        var nodes: [RadarPeripheralNode] = []

        for (uuid, record) in bleTelemetryMap {
            guard !record.rssiList.isEmpty else { continue }
            let values = record.rssiList.map { Double($0.val) }
            let count = values.count
            let avgRssi = values.reduce(0, +) / Double(count)

            // 计算样本标准差 (方差平方根)
            let variance = values.reduce(0) { $0 + pow($1 - avgRssi, 2) } / Double(max(count, 1))
            let stdDev = sqrt(variance)

            // 1. 无线电衰减测距模型: d = 10 ^ ((|RSSI| - A) / (10 * n))
            // 假设 A = 59 dBm (1米基准), 环境衰减常数 n = 2.2
            let absRssi = abs(avgRssi)
            let exponent = (absRssi - 59.0) / (10.0 * 2.2)
            let estimatedDist = min(20.0, max(0.5, pow(10.0, exponent)))

            // 2. 伪方位角解算：基于设备 UUID 的散列基准角 + 罗盘航向补偿
            let hashVal = abs(uuid.hashValue)
            let baseAngle = Double(hashVal % 360)
            let finalAngle = (baseAngle - currentHeadingDegrees + 360.0).truncatingRemainder(dividingBy: 360.0)

            // 3. 车载相对静止/同乘判定：
            // 样本数 >= 6，且 RSSI 标准差 <= 3.2 dBm（近乎恒定不变的同乘距离）
            let isCoMoving = count >= 6 && stdDev <= 3.2

            nodes.append(RadarPeripheralNode(
                id: uuid,
                rssi: Int(avgRssi),
                estimatedDistanceMeters: estimatedDist,
                bearingDegrees: finalAngle,
                rssiVariance: stdDev,
                sampleCount: count,
                isStaticCoMoving: isCoMoving
            ))
        }

        return nodes
    }

    // MARK: - 6. 微型多裁判裁决 AI (Truncated Consensus AI Engine)
    private func runArbitrationAI(nodes: [RadarPeripheralNode]) -> AIArbitrationResult {
        // 统计同乘/车内稳态设备
        let coMovingCount = nodes.filter { $0.isStaticCoMoving }.count
        let totalCount = nodes.count
        let strangerCount = max(0, totalCount - coMovingCount)

        // 裁判 1: BLE 人群密度裁判 (Judge A)
        // 核心规则：关注陌生流动设备数量；若检测到熟悉的低方差共动设备，主动进行动态折损
        var judgeA = 0.0
        if strangerCount >= 14 {
            judgeA = 92.0
        } else if strangerCount >= 7 {
            judgeA = 55.0 + Double(strangerCount - 7) * 5.0
        } else {
            judgeA = Double(strangerCount) * 7.0
        }
        // 如果判定出典型私家车堵车特征（多个稳定共动外设，且占比较高）
        if coMovingCount >= 2 {
            judgeA *= 0.88 // 略微拉低 12%
        }

        // 裁判 2: 网络子网拓扑裁判 (Judge B)
        var judgeB = 0.0
        if currentLanDeviceCount >= 10 {
            judgeB = 90.0
        } else if currentLanDeviceCount >= 5 {
            judgeB = 60.0
        } else if currentLanDeviceCount >= 3 {
            judgeB = 30.0
        } else {
            judgeB = 10.0
        }

        // 裁判 3: GNSS 空间衰减裁判 (Judge C)
        var judgeC = 0.0
        if gpsAccuracy < 0 || gpsAccuracy >= 40.0 {
            judgeC = 80.0 // 建筑遮蔽
        } else if gpsAccuracy >= 20.0 {
            judgeC = 45.0
        } else {
            judgeC = 15.0 // 开阔室外
        }

        // 裁判 4: 电梯动力学裁决者 (Judge D)
        var judgeD = 10.0
        let absSpeed = abs(verticalSpeed)
        if absSpeed >= 1.2 {
            judgeD = 98.0 // 瞬时绝对裁决
        }

        // 裁判 5: 惯性稳态与加重裁判 (Judge E)
        var judgeE = 20.0
        if abs(currentZAccel) > 0.15 {
            judgeE = 70.0
        }

        // 构造裁判席
        let panel: [String: Double] = [
            "BLE_Judge": judgeA,
            "LAN_Judge": judgeB,
            "GNSS_Judge": judgeC,
            "Elevator_Judge": judgeD,
            "Motion_Judge": judgeE
        ]

        // --- 裁判所法则：去除最高分与最低分 ---
        let sortedJudges = panel.sorted { $0.value < $1.value }
        let lowestJudge = sortedJudges.first!
        let highestJudge = sortedJudges.last!

        // 裁减后的中坚裁判名单 (取中间 3 名)
        let middleJudges = sortedJudges.dropFirst().dropLast()
        let truncatedSum = middleJudges.reduce(0.0) { $0 + $1.value }
        var finalConsensus = truncatedSum / Double(middleJudges.count)

        // 特殊优先权修正：电梯是强物理真值，若 Judge D > 95 则不容抹杀
        if judgeD > 95.0 {
            finalConsensus = max(finalConsensus, 92.0)
        }

        // 语义分析与综合理由推导
        var rationale = ""
        var category = "私密 / 车载空间"
        var confidence = 0.85

        if judgeD > 95.0 {
            category = "垂直运载设施 (电梯轿厢)"
            confidence = 0.98
            rationale = "检测到持续的气压梯度与垂直重力过载，动力学特征唯一，以最高裁判准则直接定性为电梯。"
        } else if finalConsensus >= 62.0 {
            category = "高密度公共开放空间"
            confidence = min(0.95, finalConsensus / 100.0)
            rationale = "多数裁判形成共识：剔除极端指标后，陌生蓝牙设备分布广阔且局域网节点密集，符合商业综合体或交通大厅特征。"
        } else if coMovingCount >= 2 && strangerCount <= 8 {
            category = "车内独立空间 (车流同乘态)"
            confidence = 0.89
            rationale = "AI检测到 \(coMovingCount) 个外设的信号强度标准差低于 3.2dBm，呈现严格的空间相对静止，符合私家车或随身外设陪伴场景，已执行基线折损拉低指数。"
        } else if finalConsensus >= 40.0 {
            category = "半私密办公 / 缓冲区"
            confidence = 0.72
            rationale = "环境呈现轻微设备流动，但未达到大型公共场所判定临界，归入过渡空间。"
        } else {
            category = "完全私密空间 (家庭/独处)"
            confidence = 0.90
            rationale = "各裁判打分均处于低位基线，无外部陌生信号干扰，网络为封闭私网。"
        }

        return AIArbitrationResult(
            finalScore: min(100.0, max(0.0, finalConsensus)),
            category: category,
            confidence: confidence,
            rationale: rationale,
            judgeScores: panel,
            trimmedOutliers: [lowestJudge.key, highestJudge.key]
        )
    }

    // MARK: - 7. 导出全量载荷供前端渲染
    public func evaluateCurrentEnvironment() -> [String: Any] {
        let radarNodes = computeRadarNodes()
        let aiDecision = runArbitrationAI(nodes: radarNodes)

        // 序列化雷达节点
        let serializedNodes: [[String: Any]] = radarNodes.map { node in
            return [
                "id": node.id,
                "rssi": node.rssi,
                "distance": Double(round(node.estimatedDistanceMeters * 10) / 10),
                "bearing": Double(round(node.bearingDegrees * 10) / 10),
                "variance": Double(round(node.rssiVariance * 100) / 100),
                "is_comoving": node.isStaticCoMoving
            ]
        }

        return [
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "heading": currentHeadingDegrees,
            "metrics": [
                "vertical_speed_m_s": String(format: "%.2f", verticalSpeed),
                "z_acceleration": String(format: "%.3f", currentZAccel),
                "gps_accuracy_m": String(format: "%.1f", gpsAccuracy),
                "lan_devices_count": currentLanDeviceCount
            ],
            "radar_peripherals": serializedNodes,
            "ai_arbitration": [
                "score": Double(round(aiDecision.finalScore * 10) / 10),
                "category": aiDecision.category,
                "confidence": Double(round(aiDecision.confidence * 100) / 100),
                "rationale": aiDecision.rationale,
                "judge_scores": aiDecision.judgeScores,
                "trimmed_judges": aiDecision.trimmedOutliers
            ]
        ]
    }
}
