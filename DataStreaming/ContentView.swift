//
//  ContentView.swift
//  DataStreaming
//
//  Created by Keita Matsumoto on 2025/12/31.
//

import Foundation
import SwiftUI
import RealityKit
import ARKit
import CoreMotion
import CoreLocation
import Combine
import VideoToolbox

struct ContentView: View {
    @StateObject private var sensorManager = SensorManager()
    
    @State private var serverAddress = "192.168.0.10"
    @State private var serverPort = "8080"
    @State private var useWebRTC = true

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
                
                Divider().padding(.vertical, 4)
                HStack(spacing: 6) {
                    TextField("IP", text: $serverAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    Text(":")
                    TextField("Port", text: $serverPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .keyboardType(.numberPad)
                    Toggle("WebRTC", isOn: $useWebRTC)
                        .labelsHidden()
                    Button("接続") {
                        let urlString = "http://\(serverAddress):\(serverPort)"
                        sensorManager.configureTransport(baseURLString: urlString, useWebRTC: useWebRTC)
                    }
                    .buttonStyle(.borderedProminent)
                }
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
    @Published var cameraState: String = "idle"
    @Published var depthState: String = "idle"
    @Published var imuState: String = "idle"
    @Published var locationState: String = "idle"

    // MARK: - AR
    private let arSession = ARSession()
    
    // MARK: - Video Encoding (H.264)
    private var vtSession: VTCompressionSession?
    private var videoWidth: Int32 = 0
    private var videoHeight: Int32 = 0
    private var videoSeq: UInt32 = 0

    // MARK: - Motion
    private let motion = CMMotionManager()

    // MARK: - Location
    private let locationManager = CLLocationManager()

    // MARK: - Transport
-    private let transport: Transport = LocalStubTransport(baseURL: URL(string: "http://127.0.0.1:8080")!)
+    private var transport: Transport? = nil
    private var seqVideo: UInt32 = 0
    private var seqPoint: UInt32 = 0
    private var seqIMU: UInt32 = 0
    private var seqLoc: UInt32 = 0

    private func nowUnixNanos() -> UInt64 {
        let t = Date().timeIntervalSince1970
        return UInt64(t * 1_000_000_000)
    }

+    func configureTransport(baseURLString: String, useWebRTC: Bool) {
+        guard let url = URL(string: baseURLString) else { return }
+        if useWebRTC {
+            let w = WebRTCTransport(signalingURL: url)
+            self.transport = w
+            w.start()
+        } else {
+            self.transport = LocalStubTransport(baseURL: url)
+        }
+    }
+
    override init() {
        super.init()
        arSession.delegate = self
        locationManager.delegate = self
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

    // MARK: - H.264 setup
    private func setupH264EncoderIfNeeded(width: Int32, height: Int32) {
        if let s = vtSession, videoWidth == width && videoHeight == height {
            return
        }
        if let old = vtSession {
            VTCompressionSessionInvalidate(old)
            vtSession = nil
        }
        videoWidth = width
        videoHeight = height

        var newSession: VTCompressionSession? = nil
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: width,
                                                height: height,
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: { refCon, _, status, infoFlags, sampleBuffer in
            guard status == noErr, let sbuf = sampleBuffer, CMSampleBufferDataIsReady(sbuf) else { return }
            let encoder = Unmanaged<SensorManager>.fromOpaque(refCon!).takeUnretainedValue()
            encoder.handleEncodedSampleBuffer(sbuf)
        },
                                                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                                compressionSessionOut: &newSession)
        guard status == noErr, let session = newSession else {
            print("VTCompressionSessionCreate failed: \(status)")
            return
        }
        vtSession = session

        // Realtime & profile
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        // Keyframe interval
        var keyInt: Int32 = 60
        let keyIntNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &keyInt)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyIntNum)
        // Average bitrate (例: 4Mbps)
        var bitrate: Int32 = 4_000_000
        let bitrateNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &bitrate)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateNum)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // SPS/PPS 抽出
        var spsData: Data?
        var ppsData: Data?
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>? = nil
            var size: Int = 0
            var hdrLen: Int32 = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &hdrLen)
            if let p = ptr {
                let nal = Data(bytes: p, count: size)
                if nal.first == 0x67 { spsData = nal } // SPS
                else if nal.first == 0x68 { ppsData = nal } // PPS
            }
        }

        // Annex B形式で出力（00 00 00 01 + NAL）
        func annexB(_ nal: Data) -> Data {
            var start: [UInt8] = [0,0,0,1]
            var d = Data(bytes: &start, count: 4)
            d.append(nal)
            return d
        }

        var out = Data()
        if let sps = spsData { out.append(annexB(sps)) }
        if let pps = ppsData { out.append(annexB(pps)) }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard let dp = dataPointer else { return }

        var offset = 0
        while offset + 4 < totalLength {
            // AVCC length-prefixed NAL -> Annex B
            let nalLength = dp.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }.bigEndian
            let nalStart = offset + 4
            let nal = Data(bytes: dp.advanced(by: nalStart), count: Int(nalLength))
            out.append(annexB(nal))
            offset += 4 + Int(nalLength)
        }

        // ここで out が1フレームのAnnexB H.264バイト列
        videoSeq &+= 1
        seqVideo &+= 1
        let ts = nowUnixNanos()
-        transport.send(sensor: .video, timestampNanos: ts, sequence: seqVideo, payload: out)
+        transport?.send(sensor: .video, timestampNanos: ts, sequence: seqVideo, payload: out)
        print("H264 frame bytes: \(out.count) seq: \(videoSeq)")
    }

    private func encodePixelBufferH264(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session = vtSession else { return }
        let flags: VTEncodeInfoFlags = []
-        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: UnsafeMutablePointer(mutating: [flags]))
+        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: UnsafeMutablePointer(mutating: [flags]))
    }

    // MARK: - Point Cloud
    struct PointXYZRGB {
        var x: Float
        var y: Float
        var z: Float
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

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
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0 // 100 Hz
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, err in
            guard let self, let dm else { return }
            // timestamp は起動後の経過秒
            let t = dm.timestamp
            let acc = dm.userAcceleration
            let gyro = dm.rotationRate
            let quat = dm.attitude.quaternion
            self.imuState = String(format: "%.2f s  ax:%.2f ay:%.2f az:%.2f", t, acc.x, acc.y, acc.z)
            // IMU送信（単発）
            var payload = Data()
            // timestampDeltaNanos は簡易的に0を入れる
            var zero32: UInt32 = 0
            payload.append(Data(bytes: &zero32, count: 4))
            var ax = Float32(acc.x), ay = Float32(acc.y), az = Float32(acc.z)
            var gx = Float32(dm.rotationRate.x), gy = Float32(dm.rotationRate.y), gz = Float32(dm.rotationRate.z)
            var qw = Float32(quat.w), qx = Float32(quat.x), qy = Float32(quat.y), qz = Float32(quat.z)
            for v in [ax, ay, az, gx, gy, gz, qw, qx, qy, qz] {
                var vv = v
                withUnsafeBytes(of: &vv) { payload.append(contentsOf: $0) }
            }
            seqIMU &+= 1
            transport?.send(sensor: .imu, timestampNanos: nowUnixNanos(), sequence: seqIMU, payload: payload)
        }
        imuState = "running"
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
        // カラー画像
        let pixelBuffer = frame.capturedImage
        // 深度（対応端末のみ）
        if let depth = frame.sceneDepth ?? frame.smoothedSceneDepth {
            let pts = generatePointCloud(from: depth, frame: frame, downsample: 4)
            depthState = String(format: "t:%.2f depth: w:%d h:%d pts:%d", t, CVPixelBufferGetWidth(depth.depthMap), CVPixelBufferGetHeight(depth.depthMap), pts.count)
            // 点群送信（XYZRGB float32 + uint8 をそのまま詰める簡易版）
            var payload = Data()
            // count (UInt32 little endian)
            var countLE = UInt32(pts.count).littleEndian
            payload.append(Data(bytes: &countLE, count: 4))
            for p in pts {
                var x = p.x, y = p.y, z = p.z
                withUnsafeBytes(of: &x) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: &z) { payload.append(contentsOf: $0) }
                payload.append(contentsOf: [p.r, p.g, p.b])
            }
            seqPoint &+= 1
-            transport.send(sensor: .pointCloud, timestampNanos: nowUnixNanos(), sequence: seqPoint, payload: payload)
+            transport?.send(sensor: .pointCloud, timestampNanos: nowUnixNanos(), sequence: seqPoint, payload: payload)
        } else {
            depthState = "no-depth"
        }

        // H.264 エンコード
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        setupH264EncoderIfNeeded(width: w, height: h)
        encodePixelBufferH264(pixelBuffer, pts: CMTime(seconds: t, preferredTimescale: 1_000_000_000))
        cameraState = String(format: "t:%.2f w:%d h:%d", t, w, h)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        cameraState = "error: \(error.localizedDescription)"
    }
}

// MARK: - CLLocationManagerDelegate
extension SensorManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            locationState = "running"
        case .denied, .restricted:
            locationState = "denied"
        case .notDetermined:
            locationState = "requesting"
        @unknown default:
            locationState = "unknown"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let t = loc.timestamp.timeIntervalSince1970
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        let acc = loc.horizontalAccuracy
        locationState = String(format: "t:%.0f  lat:%.5f lon:%.5f ±%.1fm", t, lat, lon, acc)
        // 位置情報送信（簡易バイナリ）
        var payload = Data()
        var latLE = lat.bitPattern.littleEndian
        var lonLE = lon.bitPattern.littleEndian
        var altLE = loc.altitude.bitPattern.littleEndian
        var hAccLE = loc.horizontalAccuracy.bitPattern.littleEndian
        var vAccLE = loc.verticalAccuracy.bitPattern.littleEndian
        var speedLE = loc.speed.bitPattern.littleEndian
        var courseLE = loc.course.bitPattern.littleEndian
        payload.append(Data(bytes: &latLE, count: 8))
        payload.append(Data(bytes: &lonLE, count: 8))
        payload.append(Data(bytes: &altLE, count: 8))
        payload.append(Data(bytes: &hAccLE, count: 4))
        payload.append(Data(bytes: &vAccLE, count: 4))
        payload.append(Data(bytes: &speedLE, count: 4))
        payload.append(Data(bytes: &courseLE, count: 4))
        seqLoc &+= 1
-        transport.send(sensor: .location, timestampNanos: nowUnixNanos(), sequence: seqLoc, payload: payload)
+        transport?.send(sensor: .location, timestampNanos: nowUnixNanos(), sequence: seqLoc, payload: payload)
        // TODO: サーバ送信用に構造体化して送信
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationState = "error: \(error.localizedDescription)"
    }
}

#Preview {
    ContentView()
}

