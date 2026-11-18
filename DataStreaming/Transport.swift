import Foundation

public enum SensorType: UInt8 {
    case video = 0
    case pointCloud = 1
    case imu = 2
    case location = 3
}

public struct PacketHeader {
    public static let magic: UInt32 = 0x44535452 // 'DSTR'
    public static let version: UInt8 = 1

    public var sensor: SensorType
    public var timestampNanos: UInt64
    public var sequence: UInt32
    public var payloadLength: UInt32

    public func encode() -> Data {
        var data = Data()
        var m = PacketHeader.magic.littleEndian
        data.append(Data(bytes: &m, count: 4))
        var v = PacketHeader.version
        data.append(Data(bytes: &v, count: 1))
        var st = sensor.rawValue
        data.append(Data(bytes: &st, count: 1))
        var reserved: UInt16 = 0
        data.append(Data(bytes: &reserved, count: 2))
        var ts = timestampNanos.littleEndian
        data.append(Data(bytes: &ts, count: 8))
        var seq = sequence.littleEndian
        data.append(Data(bytes: &seq, count: 4))
        var len = payloadLength.littleEndian
        data.append(Data(bytes: &len, count: 4))
        return data
    }
}

public protocol Transport {
    func send(sensor: SensorType, timestampNanos: UInt64, sequence: UInt32, payload: Data)
}

public final class LocalStubTransport: Transport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(sensor: SensorType, timestampNanos: UInt64, sequence: UInt32, payload: Data) {
        let header = PacketHeader(sensor: sensor, timestampNanos: timestampNanos, sequence: sequence, payloadLength: UInt32(payload.count)).encode()
        var body = Data()
        body.append(header)
        body.append(payload)

        let path: String
        switch sensor {
        case .video: path = "/ingest/video"
        case .pointCloud: path = "/ingest/pointcloud"
        case .imu: path = "/ingest/imu"
        case .location: path = "/ingest/location"
        }
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let task = session.dataTask(with: req) { _, resp, err in
            if let err = err {
                print("[Transport] send error: \(err.localizedDescription)")
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                print("[Transport] HTTP status: \(http.statusCode)")
            }
        }
        task.resume()
    }
}
