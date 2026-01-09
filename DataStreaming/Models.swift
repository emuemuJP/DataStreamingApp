//
//  Models.swift
//  DataStreaming
//
//  Created by Claude on 2026/01/09.
//

import Foundation
import simd
import CoreLocation

// MARK: - Timestamp Synchronization

/// ホスト時刻を基準とした同期タイムスタンプ
struct SyncTimestamp: Codable, Equatable {
    /// システム起動からの経過時間（秒）
    let hostTime: TimeInterval
    /// UNIX時刻（エポック秒）
    let unixTime: TimeInterval

    static func now() -> SyncTimestamp {
        let hostTime = ProcessInfo.processInfo.systemUptime
        let unixTime = Date().timeIntervalSince1970
        return SyncTimestamp(hostTime: hostTime, unixTime: unixTime)
    }

    /// ARFrame.timestamp や CMDeviceMotion.timestamp からの変換
    static func fromSensorTimestamp(_ sensorTime: TimeInterval) -> SyncTimestamp {
        let hostTime = sensorTime
        let bootTime = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        let unixTime = bootTime + sensorTime
        return SyncTimestamp(hostTime: hostTime, unixTime: unixTime)
    }
}

// MARK: - IMU Data

/// 3軸ベクトルデータ
struct Vector3: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = Vector3(x: 0, y: 0, z: 0)
}

/// クォータニオン（姿勢表現）
struct Quaternion: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double

    static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
}

/// IMUデータスナップショット
struct IMUSnapshot: Codable, Equatable {
    let timestamp: SyncTimestamp
    /// ユーザー加速度（重力除去済み、単位: G）
    let userAcceleration: Vector3
    /// 回転速度（単位: rad/s）
    let rotationRate: Vector3
    /// 姿勢（クォータニオン）
    let attitude: Quaternion
    /// 重力ベクトル（単位: G）
    let gravity: Vector3
}

// MARK: - Location Data

/// 位置情報スナップショット
struct LocationSnapshot: Codable, Equatable {
    let timestamp: SyncTimestamp
    /// 緯度（度）
    let latitude: Double
    /// 経度（度）
    let longitude: Double
    /// 高度（メートル）
    let altitude: Double
    /// 水平精度（メートル）
    let horizontalAccuracy: Double
    /// 垂直精度（メートル）
    let verticalAccuracy: Double
    /// 進行方向（度、北=0）
    let course: Double
    /// 速度（m/s）
    let speed: Double
}

extension LocationSnapshot {
    init(from location: CLLocation) {
        self.timestamp = SyncTimestamp(
            hostTime: ProcessInfo.processInfo.systemUptime,
            unixTime: location.timestamp.timeIntervalSince1970
        )
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.course = location.course
        self.speed = location.speed
    }
}

// MARK: - Camera/AR Data

/// カメラ内部パラメータ
struct CameraIntrinsics: Codable, Equatable {
    /// 焦点距離X（ピクセル）
    let fx: Float
    /// 焦点距離Y（ピクセル）
    let fy: Float
    /// 主点X（ピクセル）
    let cx: Float
    /// 主点Y（ピクセル）
    let cy: Float
}

/// 4x4変換行列（行優先）
struct Transform4x4: Codable, Equatable {
    let m: [Float] // 16要素

    init(from matrix: simd_float4x4) {
        self.m = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    static let identity = Transform4x4(from: matrix_identity_float4x4)
}

/// ARフレームスナップショット（メタデータのみ）
struct ARFrameSnapshot: Codable, Equatable {
    let timestamp: SyncTimestamp
    /// カメラ内部パラメータ
    let intrinsics: CameraIntrinsics
    /// カメラのワールド座標変換
    let cameraTransform: Transform4x4
    /// カメラ画像の解像度
    let imageWidth: Int
    let imageHeight: Int
    /// 深度マップの解像度（利用可能な場合）
    let depthWidth: Int?
    let depthHeight: Int?
    /// トラッキング状態
    let trackingState: String
}

// MARK: - Point Cloud Data

/// 色付き3D点
struct PointXYZRGB: Codable, Equatable {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

/// ポイントクラウドスナップショット
struct PointCloudSnapshot: Codable {
    let timestamp: SyncTimestamp
    /// 点群データ
    let points: [PointXYZRGB]
    /// ダウンサンプリング係数
    let downsampleFactor: Int

    var pointCount: Int { points.count }
}

// MARK: - Unified Sensor Frame

/// 全センサーデータを統合したフレーム
struct SensorFrame: Codable {
    /// フレーム識別子
    let frameId: UInt64
    /// フレーム生成時刻
    let timestamp: SyncTimestamp

    /// ARフレームデータ（カメラ・深度メタデータ）
    let arFrame: ARFrameSnapshot?
    /// ポイントクラウド（オプション）
    let pointCloud: PointCloudSnapshot?
    /// IMUデータ
    let imu: IMUSnapshot?
    /// 位置情報
    let location: LocationSnapshot?

    /// センサーフレームのJSONエンコード
    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// JSON Linesフォーマット用の1行文字列
    func toJSONLine() throws -> String {
        let data = try toJSON()
        guard let str = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "UTF-8 encoding failed"))
        }
        return str + "\n"
    }
}

// MARK: - Recording Session Metadata

/// 録画セッションのメタデータ
struct RecordingSessionMetadata: Codable {
    /// セッション識別子
    let sessionId: String
    /// 開始時刻
    let startTime: SyncTimestamp
    /// 終了時刻（録画中はnil）
    var endTime: SyncTimestamp?
    /// デバイス情報
    let deviceModel: String
    let osVersion: String
    /// 設定情報
    let settings: RecordingSettings
    /// フレーム数
    var frameCount: UInt64

    static func create(settings: RecordingSettings) -> RecordingSessionMetadata {
        return RecordingSessionMetadata(
            sessionId: UUID().uuidString,
            startTime: .now(),
            endTime: nil,
            deviceModel: deviceModelIdentifier(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: settings,
            frameCount: 0
        )
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}

/// 録画設定
struct RecordingSettings: Codable, Equatable {
    /// IMUサンプリングレート（Hz）
    var imuSamplingRate: Double = 100.0
    /// ポイントクラウドのダウンサンプリング係数
    var pointCloudDownsample: Int = 4
    /// 深度センシングを有効にするか
    var enableDepth: Bool = true
    /// 位置情報を有効にするか
    var enableLocation: Bool = true
    /// ポイントクラウドを記録するか
    var recordPointCloud: Bool = false

    static let `default` = RecordingSettings()
}

// MARK: - Sensor Status

/// センサーの状態
enum SensorStatus: String, Codable {
    case idle = "idle"
    case running = "running"
    case paused = "paused"
    case error = "error"
    case unavailable = "unavailable"
    case denied = "denied"
}

/// 全センサーの統合状態
struct SensorSystemStatus: Equatable {
    var camera: SensorStatus = .idle
    var depth: SensorStatus = .idle
    var imu: SensorStatus = .idle
    var location: SensorStatus = .idle
    var isRecording: Bool = false

    var isAllRunning: Bool {
        camera == .running && imu == .running
    }
}
