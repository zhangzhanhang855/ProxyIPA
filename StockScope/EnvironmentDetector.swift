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
    @objc public static let shared = EnvironmentDetector()

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

    @objc public func startMonitoring() {
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

    // MARK: - 4. 局域网活动扫描 (Network.framework)
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
            let absRssi = abs(avgRssi)
            let exponent = (absRssi - 59.0) / (10.0 * 2.2)
            let estimatedDist = min(20.0, max(0.5, pow(10.0, exponent)))

            // 2. 伪方位角解算：散列基准角 + 罗盘航向补偿
            let hashVal = abs(uuid.hashValue)
            let baseAngle = Double(hashVal % 360)
            let finalAngle = (baseAngle - currentHeadingDegrees + 360.0).truncatingRemainder(dividingBy: 360.0)

            // 3. 车载相对静止/同乘判定：样本充足且 RSSI 标准差 <= 3.2 dBm
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

    // MARK: - 6. 自适应微型 AI 裁判席 (破除饭店误剪与地铁误判)
    private func runArbitrationAI(nodes: [RadarPeripheralNode]) -> AIArbitrationResult {
        let totalCount = nodes.count
        let coMovingNodes = nodes.filter { $0.isStaticCoMoving }
        let coMovingCount = coMovingNodes.count

        // 核心判别 1：私家车座舱容积物理天花板校验
        // 私家车哪怕满载+前后邻车，整体高信噪比设备总盘很少突破 8 台。
        // 若总设备数 >= 12，即使有人静止，也是典型的【地铁车厢 / 公交车】！
        let isPublicTransit = totalCount >= 12 && coMovingCount >= 2
        let isPrivateCabin = (totalCount <= 8) && (coMovingCount >= 2)

        // 裁判 1: BLE 人群密度裁判 (Judge A)
        var judgeA = 0.0
        if totalCount >= 18 {
            judgeA = 96.0 // 无论如何，18台以上必定是大型公共场所/地铁
        } else if totalCount >= 10 {
            judgeA = 75.0 + Double(totalCount - 10) * 2.5
        } else if totalCount >= 5 {
            judgeA = 40.0 + Double(totalCount - 5) * 6.0
        } else {
            judgeA = Double(totalCount) * 8.0
        }

        // 只有严格确认在私家车物理特征内，才执行衰减折损
        if isPrivateCabin {
            judgeA *= 0.85 // 执行私家车 15% 衰减折损
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
            judgeB = 10.0 // 饭店私有热点或蜂窝数据下给低分
        }

        // 裁判 3: GNSS 空间衰减裁判 (Judge C)
        var judgeC = 0.0
        if gpsAccuracy < 0 || gpsAccuracy >= 35.0 {
            judgeC = 80.0 // 室内深处或地铁地下无星
        } else if gpsAccuracy >= 18.0 {
            judgeC = 45.0
        } else {
            judgeC = 15.0 // 开阔室外马路
        }

        // 裁判 4: 电梯动力学裁决者 (Judge D)
        var judgeD = 10.0
        let absSpeed = abs(verticalSpeed)
        if absSpeed >= 1.2 {
            judgeD = 98.0
        }

        // 裁判 5: 惯性稳态与加重裁判 (Judge E)
        var judgeE = 15.0
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

        var finalConsensus = 0.0
        var trimmedOutliers: [String] = []
        var rationale = ""
        var category = "私密 / 车载空间"
        var confidence = 0.85

        // ================= 智能共识仲裁层 =================

        // 特殊场景 A：电梯绝对物理优先
        if judgeD > 95.0 {
            category = "垂直运载设施 (电梯轿厢)"
            confidence = 0.98
            finalConsensus = 95.0
            rationale = "检测到持续的气压梯度与垂直重力过载，动力学特征唯一，以最高优先权直接定性为电梯。"
        }
        // 特殊场景 B：地铁车厢识别（大量设备 + 稳态人群 + 地下GNSS缺失）
        else if isPublicTransit && (gpsAccuracy >= 30.0 || gpsAccuracy < 0) {
            category = "公共交通载具 (地铁车厢/公交)"
            confidence = 0.94
            finalConsensus = max(78.0, judgeA)
            rationale = "检测到高密度设备池 (\(totalCount)台) 伴随地下空间遮蔽。虽有同乘相对静止，但整体基数超出私家车物理容量，定性为公共交通。"
        }
        // 特殊场景 C：饭店/餐饮聚集区（BLE极高，但LAN与Motion静止）
        // 关键修复点：防止将饭店唯一的 BLE 高分当成噪点砍掉！
        else if judgeA >= 70.0 && (gpsAccuracy >= 20.0 || gpsAccuracy < 0) && !isPrivateCabin {
            category = "高密度室内公共区 (餐厅/商场)"
            confidence = 0.91
            finalConsensus = (judgeA * 0.65) + (judgeC * 0.25) + (judgeB * 0.10)
            trimmedOutliers = ["Motion_Judge", "Elevator_Judge"]
            rationale = "室内环境下无线电人群密度极高，检测到餐厅/商业区特征。微型AI主动挂起惯性静止裁判，保留人流高分裁决。"
        }
        // 特殊场景 D：真实私家车堵车
        else if isPrivateCabin {
            category = "私家车座舱 (堵车同乘态)"
            confidence = 0.92
            finalConsensus = min(42.0, (judgeA * 0.5) + (judgeC * 0.3) + (judgeB * 0.2))
            rationale = "设备总基数符合小型车舱物理界限 (\(totalCount)台)，且观测到恒定距离同乘信标，成功抵扣外部车流干扰，定性为私密空间。"
        }
        // 默认场景：标准受约束的奥运剪裁算法
        else {
            let sortedJudges = panel.sorted { $0.value < $1.value }
            let lowest = sortedJudges.first!
            let highest = sortedJudges.last!

            trimmedOutliers = [lowest.key, highest.key]
            let middleJudges = sortedJudges.dropFirst().dropLast()
            let avg = middleJudges.reduce(0.0) { $0 + $1.value } / Double(middleJudges.count)

            finalConsensus = avg
            if finalConsensus >= 62.0 {
                category = "高密度公共开放空间"
                confidence = min(0.95, finalConsensus / 100.0)
                rationale = "多裁判共识裁定：剔除极值后，周边设备分布与网络拓扑呈现标准公共空间特征。"
            } else if finalConsensus >= 40.0 {
                category = "半私密办公 / 缓冲区"
                confidence = 0.70
                rationale = "环境呈现轻微设备流动，但未达到大型公共场所临界点。"
            } else {
                category = "完全私密空间 (家庭/独处)"
                confidence = 0.90
                rationale = "各项指标均处于低位基线，无外部陌生信号干扰。"
            }
        }

        return AIArbitrationResult(
            finalScore: min(100.0, max(0.0, finalConsensus)),
            category: category,
            confidence: confidence,
            rationale: rationale,
            judgeScores: panel,
            trimmedOutliers: trimmedOutliers
        )
    }

    // MARK: - 7. 导出全量载荷供前端渲染
    @objc public func evaluateCurrentEnvironment() -> [String: Any] {
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
