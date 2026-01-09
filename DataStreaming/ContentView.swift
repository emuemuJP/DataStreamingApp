//
//  ContentView.swift
//  DataStreaming
//
//  Created by Keita Matsumoto on 2025/12/31.
//

import SwiftUI
import RealityKit
import ARKit
import CoreMotion
import CoreLocation
import Combine

struct ContentView: View {
    @StateObject private var sensorManager = SensorManager()
    @State private var showSettings = false
    @State private var isSessionActive = false

    var body: some View {
        ZStack {
            // RealityView と ARSession を連携
            RealityView { content in
                content.camera = .spatialTracking
            } update: { content in
                // Anchor/Modelなどの可視化は後で拡張
            } placeholder: {
                Color.clear
            }
            .ignoresSafeArea()

            // オーバーレイUI
            VStack {
                // 上部: 設定ボタン
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(isSessionActive)
                    .opacity(isSessionActive ? 0.5 : 1.0)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()

                // 下部: ステータスと録画コントロール
                VStack(spacing: 12) {
                    // センサー状態表示
                    SensorStatusPanel(sensorManager: sensorManager)

                    // 録画コントロール
                    SessionControlPanel(
                        isActive: $isSessionActive,
                        isRecording: $sensorManager.status.isRecording,
                        onStart: { sensorManager.startAll() },
                        onStop: { sensorManager.stopAll() }
                    )
                }
                .padding()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $sensorManager.settings)
        }
    }
}

// MARK: - Sensor Status Panel

struct SensorStatusPanel: View {
    @ObservedObject var sensorManager: SensorManager

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                StatusIndicator(
                    icon: "camera.fill",
                    label: "Camera",
                    status: sensorManager.status.camera
                )
                StatusIndicator(
                    icon: "cube.transparent",
                    label: "Depth",
                    status: sensorManager.status.depth
                )
                StatusIndicator(
                    icon: "gyroscope",
                    label: "IMU",
                    status: sensorManager.status.imu
                )
                StatusIndicator(
                    icon: "location.fill",
                    label: "Location",
                    status: sensorManager.status.location
                )
            }

            // 詳細情報
            VStack(spacing: 2) {
                Text(sensorManager.cameraState)
                Text(sensorManager.depthState)
                Text(sensorManager.imuState)
                Text(sensorManager.locationState)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let icon: String
    let label: String
    let status: SensorStatus

    var statusColor: Color {
        switch status {
        case .running:
            return .green
        case .paused:
            return .yellow
        case .error:
            return .red
        case .unavailable, .denied:
            return .gray
        case .idle:
            return .blue
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(statusColor)
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Session Control Panel

struct SessionControlPanel: View {
    @Binding var isActive: Bool
    @Binding var isRecording: Bool
    var onStart: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            // 開始/停止ボタン
            Button {
                if isActive {
                    onStop()
                    isActive = false
                    isRecording = false
                } else {
                    onStart()
                    isActive = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "stop.fill" : "play.fill")
                    Text(isActive ? "停止" : "開始")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(isActive ? Color.red : Color.green, in: Capsule())
            }

            // 録画ボタン（セッションがアクティブな場合のみ有効）
            Button {
                isRecording.toggle()
            } label: {
                Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(isRecording ? .red : .white)
                    .symbolEffect(.pulse, options: .repeating, isActive: isRecording)
            }
            .disabled(!isActive)
            .opacity(isActive ? 1.0 : 0.5)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

final class SensorManager: NSObject, ObservableObject {
    // MARK: - Published states
    @Published var status = SensorSystemStatus()
    @Published var cameraState: String = "idle"
    @Published var depthState: String = "idle"
    @Published var imuState: String = "idle"
    @Published var locationState: String = "idle"

    // MARK: - Latest sensor data (structured)
    @Published private(set) var latestARFrame: ARFrameSnapshot?
    @Published private(set) var latestPointCloud: PointCloudSnapshot?
    @Published private(set) var latestIMU: IMUSnapshot?
    @Published private(set) var latestLocation: LocationSnapshot?

    // MARK: - Settings
    @Published var settings = RecordingSettings.default

    // MARK: - Frame counter
    private var frameCounter: UInt64 = 0

    // MARK: - AR
    private let arSession = ARSession()

    // MARK: - Motion
    private let motion = CMMotionManager()

    // MARK: - Location
    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        arSession.delegate = self
        locationManager.delegate = self
    }

    // MARK: - Current sensor frame
    func currentSensorFrame() -> SensorFrame {
        frameCounter += 1
        return SensorFrame(
            frameId: frameCounter,
            timestamp: .now(),
            arFrame: latestARFrame,
            pointCloud: settings.recordPointCloud ? latestPointCloud : nil,
            imu: latestIMU,
            location: latestLocation
        )
    }

    // MARK: - Public control
    func startAll() {
        startAR()
        startMotion()
        startLocation()
    }

    func stopAll() {
        arSession.pause()
        motion.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
    }

    // MARK: - AR setup
    private func startAR() {
        guard ARWorldTrackingConfiguration.isSupported else {
            cameraState = "unsupported"
            depthState = "unsupported"
            return
        }

        let config = ARWorldTrackingConfiguration()

        // カラー画像（標準）
        config.frameSemantics.insert(.sceneDepth)
        // LiDAR 対応端末では .sceneDepth/.smoothedSceneDepth が有効
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        // 平面検出は任意（点群/メッシュ化の足がかり）
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        // セッション開始
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        cameraState = "running"
        depthState = (ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) ? "enabled" : "unavailable")
    }

    // MARK: - Point Cloud (using PointXYZRGB from Models.swift)

    private func generatePointCloud(from depth: ARDepthData, frame: ARFrame, downsample: Int = 4) -> [PointXYZRGB] {
        // depth.depthMap: CVPixelBuffer (kCVPixelFormatType_DepthFloat32)
        let depthMap = depth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // カラー画像（NV12: plane 0 = Y, plane 1 = CbCr）
        let colorBuffer = frame.capturedImage
        let colorWidth = CVPixelBufferGetWidthOfPlane(colorBuffer, 0)
        let colorHeight = CVPixelBufferGetHeightOfPlane(colorBuffer, 0)

        // カメラ内パラメータ
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0,0]
        let fy = intrinsics[1,1]
        let cx = intrinsics[0,2]
        let cy = intrinsics[1,2]

        // 深度とカラーの解像度が異なる場合があるため、カラー座標はスケール
        let sx = Float(colorWidth) / Float(width)
        let sy = Float(colorHeight) / Float(height)

        // カメラ→ワールド変換
        let camToWorld = frame.camera.transform // simd_float4x4

        // ロック
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(colorBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(colorBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let depthPtr = depthBase.bindMemory(to: Float32.self, capacity: width * height)

        // Y面
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(colorBuffer, 0) else { return [] }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(colorBuffer, 0)
        // UV面（CbCrが交互）
        guard let uvBase = CVPixelBufferGetBaseAddressOfPlane(colorBuffer, 1) else { return [] }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(colorBuffer, 1)

        var points: [PointXYZRGB] = []
        points.reserveCapacity(max(1, (width / downsample) * (height / downsample)))

        for v in stride(from: 0, to: height, by: downsample) {
            for u in stride(from: 0, to: width, by: downsample) {
                let d = depthPtr[v * width + u]
                if !d.isFinite || d <= 0 { continue }

                // ピクセル -> カメラ座標
                let Xc = (Float(u) - cx) / fx * d
                let Yc = (Float(v) - cy) / fy * d
                let Zc = d

                // カメラ座標 -> ワールド座標
                let camPoint = simd_float4(Xc, Yc, Zc, 1.0)
                let worldPoint = camToWorld * camPoint

                // 対応するカラー画素座標（Y面）
                let cu = min(max(Int(Float(u) * sx), 0), colorWidth - 1)
                let cv = min(max(Int(Float(v) * sy), 0), colorHeight - 1)

                // Y
                let yAddr = yBase.advanced(by: cv * yStride + cu)
                let Y = Float(yAddr.load(as: UInt8.self))

                // UV（NV12: 2x2サブサンプリング、同じ座標を使い近似）
                let uvRow = cv / 2
                let uvCol = (cu / 2) * 2 // Cb,Cr の2バイト
                let uvAddr = uvBase.advanced(by: uvRow * uvStride + uvCol)
                let Cb = Float(uvAddr.load(as: UInt8.self))
                let Cr = Float(uvAddr.advanced(by: 1).load(as: UInt8.self))

                // フルレンジBT.601近似で YCbCr(NV12) -> RGB 変換
                // Y' = Y, Cb' = Cb - 128, Cr' = Cr - 128
                let Yp = Y
                let Cbp = Cb - 128.0
                let Crp = Cr - 128.0
                var R = Yp + 1.402 * Crp
                var G = Yp - 0.344136 * Cbp - 0.714136 * Crp
                var B = Yp + 1.772 * Cbp
                R = min(max(R, 0), 255)
                G = min(max(G, 0), 255)
                B = min(max(B, 0), 255)

                points.append(PointXYZRGB(
                    x: worldPoint.x,
                    y: worldPoint.y,
                    z: worldPoint.z,
                    r: UInt8(R), g: UInt8(G), b: UInt8(B)
                ))
            }
        }

        return points
    }

    // MARK: - Motion setup
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            imuState = "unavailable"
            status.imu = .unavailable
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / settings.imuSamplingRate
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, err in
            guard let self, let dm else { return }
            // timestamp は起動後の経過秒
            let t = dm.timestamp
            let syncTimestamp = SyncTimestamp.fromSensorTimestamp(t)

            let acc = dm.userAcceleration
            let gyro = dm.rotationRate
            let quat = dm.attitude.quaternion
            let grav = dm.gravity

            // IMUスナップショットを保存
            self.latestIMU = IMUSnapshot(
                timestamp: syncTimestamp,
                userAcceleration: Vector3(x: acc.x, y: acc.y, z: acc.z),
                rotationRate: Vector3(x: gyro.x, y: gyro.y, z: gyro.z),
                attitude: Quaternion(x: quat.x, y: quat.y, z: quat.z, w: quat.w),
                gravity: Vector3(x: grav.x, y: grav.y, z: grav.z)
            )

            self.imuState = String(format: "%.2f s  ax:%.2f ay:%.2f az:%.2f", t, acc.x, acc.y, acc.z)
            self.status.imu = .running
        }
        imuState = "running"
        status.imu = .running
    }

    // MARK: - Location setup
    private func startLocation() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.startUpdatingLocation()
        locationState = "requesting"
    }
}

// MARK: - ARSessionDelegate
extension SensorManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // カメラフレームのタイムスタンプ（秒）
        let t = frame.timestamp
        let syncTimestamp = SyncTimestamp.fromSensorTimestamp(t)

        // カメラ内部パラメータ
        let intrinsics = frame.camera.intrinsics
        let cameraIntrinsics = CameraIntrinsics(
            fx: intrinsics[0, 0],
            fy: intrinsics[1, 1],
            cx: intrinsics[0, 2],
            cy: intrinsics[1, 2]
        )

        // トラッキング状態
        let trackingState: String
        switch frame.camera.trackingState {
        case .normal:
            trackingState = "normal"
        case .limited(let reason):
            switch reason {
            case .initializing:
                trackingState = "initializing"
            case .excessiveMotion:
                trackingState = "excessiveMotion"
            case .insufficientFeatures:
                trackingState = "insufficientFeatures"
            case .relocalizing:
                trackingState = "relocalizing"
            @unknown default:
                trackingState = "unknown"
            }
        case .notAvailable:
            trackingState = "notAvailable"
        }

        // カラー画像
        let pixelBuffer = frame.capturedImage
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        // 深度（対応端末のみ）
        var depthWidth: Int?
        var depthHeight: Int?

        if let depth = frame.sceneDepth ?? frame.smoothedSceneDepth {
            depthWidth = CVPixelBufferGetWidth(depth.depthMap)
            depthHeight = CVPixelBufferGetHeight(depth.depthMap)

            let pts = generatePointCloud(from: depth, frame: frame, downsample: settings.pointCloudDownsample)

            // ポイントクラウドスナップショットを保存
            latestPointCloud = PointCloudSnapshot(
                timestamp: syncTimestamp,
                points: pts,
                downsampleFactor: settings.pointCloudDownsample
            )

            depthState = String(format: "t:%.2f w:%d h:%d pts:%d", t, depthWidth!, depthHeight!, pts.count)
            status.depth = .running
        } else {
            depthState = "no-depth"
            status.depth = .unavailable
            latestPointCloud = nil
        }

        // ARフレームスナップショットを保存
        latestARFrame = ARFrameSnapshot(
            timestamp: syncTimestamp,
            intrinsics: cameraIntrinsics,
            cameraTransform: Transform4x4(from: frame.camera.transform),
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            trackingState: trackingState
        )

        cameraState = String(format: "t:%.2f", t)
        status.camera = .running
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        cameraState = "error: \(error.localizedDescription)"
        status.camera = .error
    }
}

// MARK: - CLLocationManagerDelegate
extension SensorManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization authStatus: CLAuthorizationStatus) {
        switch authStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            locationState = "running"
            status.location = .running
        case .denied, .restricted:
            locationState = "denied"
            status.location = .denied
        case .notDetermined:
            locationState = "requesting"
        @unknown default:
            locationState = "unknown"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // LocationSnapshotを保存
        latestLocation = LocationSnapshot(from: loc)

        let t = loc.timestamp.timeIntervalSince1970
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        let acc = loc.horizontalAccuracy
        locationState = String(format: "t:%.0f  lat:%.5f lon:%.5f ±%.1fm", t, lat, lon, acc)
        status.location = .running
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationState = "error: \(error.localizedDescription)"
        status.location = .error
    }
}

#Preview {
    ContentView()
}

