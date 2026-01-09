//
//  RecordingManager.swift
//  DataStreaming
//
//  Created by Claude on 2026/01/09.
//

import Foundation

/// 録画状態
enum RecordingState: Equatable {
    case idle
    case recording(sessionId: String)
    case error(String)
}

/// センサーデータの録画管理
final class RecordingManager: ObservableObject {
    // MARK: - Published state
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var frameCount: UInt64 = 0
    @Published private(set) var fileSizeBytes: Int64 = 0

    // MARK: - Private properties
    private var fileHandle: FileHandle?
    private var metadata: RecordingSessionMetadata?
    private var recordingURL: URL?
    private var metadataURL: URL?

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.datastreaming.recording", qos: .userInitiated)

    // MARK: - Public methods

    /// 録画を開始
    func startRecording(settings: RecordingSettings) throws -> String {
        guard case .idle = state else {
            throw RecordingError.alreadyRecording
        }

        let sessionId = UUID().uuidString
        let documentsURL = try getDocumentsDirectory()
        let sessionDir = documentsURL.appendingPathComponent("recordings/\(sessionId)", isDirectory: true)

        // ディレクトリ作成
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // ファイルパス
        let dataURL = sessionDir.appendingPathComponent("sensor_data.jsonl")
        let metaURL = sessionDir.appendingPathComponent("metadata.json")

        // ファイル作成
        fileManager.createFile(atPath: dataURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: dataURL.path) else {
            throw RecordingError.fileCreationFailed
        }

        // メタデータ初期化
        let meta = RecordingSessionMetadata.create(settings: settings)

        self.fileHandle = handle
        self.metadata = meta
        self.recordingURL = dataURL
        self.metadataURL = metaURL
        self.frameCount = 0
        self.fileSizeBytes = 0
        self.state = .recording(sessionId: sessionId)

        // メタデータを書き込み（開始時点）
        try writeMetadata()

        return sessionId
    }

    /// フレームを録画
    func recordFrame(_ frame: SensorFrame) {
        guard case .recording = state, let handle = fileHandle else {
            return
        }

        queue.async { [weak self] in
            guard let self else { return }

            do {
                let jsonLine = try frame.toJSONLine()
                if let data = jsonLine.data(using: .utf8) {
                    handle.write(data)

                    DispatchQueue.main.async {
                        self.frameCount += 1
                        self.fileSizeBytes += Int64(data.count)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .error("Frame encoding failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 録画を停止
    func stopRecording() throws -> URL? {
        guard case .recording = state else {
            return nil
        }

        // ファイルハンドルを閉じる
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil

        // メタデータを更新（終了時刻とフレーム数）
        metadata?.endTime = .now()
        metadata?.frameCount = frameCount
        try writeMetadata()

        let sessionDir = recordingURL?.deletingLastPathComponent()

        // クリーンアップ
        self.metadata = nil
        self.recordingURL = nil
        self.metadataURL = nil
        self.state = .idle

        return sessionDir
    }

    /// 録画をキャンセル（ファイル削除）
    func cancelRecording() {
        guard case .recording = state else {
            return
        }

        try? fileHandle?.close()
        fileHandle = nil

        if let sessionDir = recordingURL?.deletingLastPathComponent() {
            try? fileManager.removeItem(at: sessionDir)
        }

        self.metadata = nil
        self.recordingURL = nil
        self.metadataURL = nil
        self.frameCount = 0
        self.fileSizeBytes = 0
        self.state = .idle
    }

    // MARK: - Session Management

    /// 保存済みセッション一覧を取得
    func listSessions() throws -> [RecordingSessionInfo] {
        let recordingsDir = try getDocumentsDirectory().appendingPathComponent("recordings", isDirectory: true)

        guard fileManager.fileExists(atPath: recordingsDir.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var sessions: [RecordingSessionInfo] = []

        for sessionDir in contents {
            let metaURL = sessionDir.appendingPathComponent("metadata.json")
            let dataURL = sessionDir.appendingPathComponent("sensor_data.jsonl")

            guard fileManager.fileExists(atPath: metaURL.path) else { continue }

            do {
                let metaData = try Data(contentsOf: metaURL)
                let metadata = try JSONDecoder().decode(RecordingSessionMetadata.self, from: metaData)

                let dataAttributes = try fileManager.attributesOfItem(atPath: dataURL.path)
                let fileSize = dataAttributes[.size] as? Int64 ?? 0

                sessions.append(RecordingSessionInfo(
                    sessionId: metadata.sessionId,
                    startTime: Date(timeIntervalSince1970: metadata.startTime.unixTime),
                    endTime: metadata.endTime.map { Date(timeIntervalSince1970: $0.unixTime) },
                    frameCount: metadata.frameCount,
                    fileSizeBytes: fileSize,
                    directoryURL: sessionDir
                ))
            } catch {
                // メタデータの読み込みに失敗したセッションはスキップ
                continue
            }
        }

        return sessions.sorted { $0.startTime > $1.startTime }
    }

    /// セッションを削除
    func deleteSession(sessionId: String) throws {
        let sessionDir = try getDocumentsDirectory()
            .appendingPathComponent("recordings/\(sessionId)", isDirectory: true)

        guard fileManager.fileExists(atPath: sessionDir.path) else {
            throw RecordingError.sessionNotFound
        }

        try fileManager.removeItem(at: sessionDir)
    }

    // MARK: - Private methods

    private func getDocumentsDirectory() throws -> URL {
        guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw RecordingError.documentsDirectoryNotFound
        }
        return url
    }

    private func writeMetadata() throws {
        guard let metadata = metadata, let metaURL = metadataURL else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metaURL)
    }
}

// MARK: - Supporting Types

struct RecordingSessionInfo: Identifiable {
    let sessionId: String
    let startTime: Date
    let endTime: Date?
    let frameCount: UInt64
    let fileSizeBytes: Int64
    let directoryURL: URL

    var id: String { sessionId }

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var formattedDuration: String {
        guard let duration else { return "Recording..." }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case fileCreationFailed
    case documentsDirectoryNotFound
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Already recording"
        case .notRecording:
            return "Not currently recording"
        case .fileCreationFailed:
            return "Failed to create recording file"
        case .documentsDirectoryNotFound:
            return "Documents directory not found"
        case .sessionNotFound:
            return "Session not found"
        }
    }
}
