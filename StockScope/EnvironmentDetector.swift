import Foundation
import CoreMotion
import CoreLocation
import AVFoundation

@objc public class EnvironmentDetector: NSObject, CLLocationManagerDelegate {
    public static let shared = EnvironmentDetector()

    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var locationManager: CLLocationManager?
    private var audioEngine: AVAudioEngine?

    private var lastPressureTime: Date?
    private var lastAltitude: Double = 0.0
    private var verticalSpeed: Double = 0.0
    private var currentZAccel: Double = 0.0
    private var currentSPL: Float = 35.0 // 默认给一个安静室内底噪
    private var gpsAccuracy: Double = -1.0

    private override init() {
        super.init()
    }

    /// 统一启动入口
    public func startMonitoring() {
        startMotionAndAltimeter()
        initLocationSafely()
        initAudioSafely()
    }

    // 1. 安全初始化定位
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

    // 2. 安全启动气压与加速度
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

    // 3. 安全配置麦克风与音频节点（防崩溃核心）
    private func initAudioSafely() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard granted else {
                print("[StockScope] 用户拒绝了麦克风权限，声学检测降级")
                return
            }
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

            // 防止模拟器或无效音频格式导致的崩溃
            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                print("[StockScope] 无效音频输入格式")
                return
            }

            inputNode.removeTap(onBus: 0) // 先移除旧 tap 防止重复绑定崩溃
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
            print("[StockScope] 音频引擎启动异常: \(error.localizedDescription)")
        }
    }

    // 定位回调
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            self.gpsAccuracy = loc.horizontalAccuracy
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[StockScope] 定位获取异常: \(error.localizedDescription)")
    }

    /// 导出监控载荷
    public func evaluateCurrentEnvironment() -> [String: Any] {
        return [
            "environment": abs(verticalSpeed) >= 1.2 ? "电梯内 (Elevator)" : "常规监测中",
            "confidence": 0.85,
            "metrics": [
                "vertical_speed_m_s": String(format: "%.2f", verticalSpeed),
                "z_acceleration": String(format: "%.3f", currentZAccel),
                "sound_level_dba": String(format: "%.1f", currentSPL),
                "gps_accuracy_m": String(format: "%.1f", gpsAccuracy)
            ]
        ]
    }
}
