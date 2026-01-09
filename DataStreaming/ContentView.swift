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

    var body: some View {
        ZStack(alignment: .bottom) {
            // RealityView と ARSession を連携
            RealityView { content in
                content.camera = .spatialTracking
            } update: { content in
                // Anchor/Modelなどの可視化は後で拡張
            } placeholder: {
                Color.clear
            }
            .ignoresSafeArea()
            .onAppear { sensorManager.startAll() }
            .onDisappear { sensorManager.stopAll() }

            // 簡易な状態表示
            VStack(spacing: 8) {
                Text("Camera: \(sensorManager.cameraState)")
                Text("Depth: \(sensorManager.depthState)")
                Text("IMU: \(sensorManager.imuState)")
                Text("Location: \(sensorManager.locationState)")
            }
            .font(.footnote)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
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

