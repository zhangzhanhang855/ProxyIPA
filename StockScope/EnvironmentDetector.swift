import Foundation
import CoreMotion
import CoreLocation
import AVFoundation

@objc public class EnvironmentDetector: NSObject, CLLocationManagerDelegate {
    public static let shared = EnvironmentDetector()

    // 传感器组件
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    private let audioEngine = AVAudioEngine()

    // 状态缓存
    private var lastPressureTime: Date?
    private var lastAltitude: Double = 0.0
    private var verticalSpeed: Double = 0.0     // 米/秒
    private var currentZAccel: Double = 0.0     // G
    private var currentSPL: Float = 0.0         // 分贝 (dBA近似)
    private var gpsAccuracy: Double = -1.0      // 水平精度 (米)

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// 开启监测
    public func startMonitoring() {
        startAltimeterAndMotion()
        startAudioLevelMonitoring()
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    // 1. 电梯特征（气压梯度 + 垂直加速度）
    private func startAltimeterAndMotion() {
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let self = self, let data = data else { return }
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
                // 提取扣除重力后的用户垂直线性加速度
                self.currentZAccel = motion.userAcceleration.z
            }
        }
    }

    // 2. 声学嘈杂度监控
    private func startAudioLevelMonitoring() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = UInt(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<Int(frameLength) {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(frameLength))
            let db = 20 * log10(max(rms, 0.0001)) + 100 // 映射为大约 0-120 dBA
            DispatchQueue.main.async {
                self?.currentSPL = db
            }
        }
        
        do {
            try audioEngine.start()
        } catch {
            print("AudioEngine 启动失败: \(error)")
        }
    }

    // 3. GNSS 衰减判定
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            self.gpsAccuracy = loc.horizontalAccuracy
        }
    }

    /// 核心判定综合输出
    public func evaluateCurrentEnvironment() -> [String: Any] {
        var detectedType = "未知 / 一般室内"
        var confidence: Double = 0.5

        let absSpeed = abs(verticalSpeed)
        
        // 判定 1: 办公楼/小区电梯
        // 阈值：升降速度 >= 1.2 m/s，且检测到非零垂直动态超失重
        if absSpeed >= 1.2 {
            detectedType = "电梯内 (Elevator)"
            confidence = absSpeed > 2.0 ? 0.96 : 0.85
        }
        // 判定 2: 大型公共空间（商场/候机大厅）
        // 阈值：GNSS 严重衰减(>35m或无锁) + 环境音级在 60~80 dBA 之间且波动剧烈
        else if (gpsAccuracy > 35.0 || gpsAccuracy < 0) && currentSPL >= 60.0 {
            detectedType = "高密度公共空间 (商场/机场大厅)"
            confidence = 0.70
        }
        // 判定 3: 宁静私人空间/小办公室
        else if (gpsAccuracy > 15.0 || gpsAccuracy < 0) && currentSPL < 45.0 {
            detectedType = "相对安静室内 (家庭/安静独立办公室)"
            confidence = 0.60
        }

        return [
            "environment": detectedType,
            "confidence": confidence,
            "metrics": [
                "vertical_speed_m_s": String(format: "%.2f", verticalSpeed),
                "z_acceleration": String(format: "%.3f", currentZAccel),
                "sound_level_dba": String(format: "%.1f", currentSPL),
                "gps_accuracy_m": String(format: "%.1f", gpsAccuracy)
            ]
        ]
    }
}
