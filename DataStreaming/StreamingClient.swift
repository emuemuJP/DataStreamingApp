//
//  StreamingClient.swift
//  DataStreaming
//
//  Created by Claude on 2026/01/09.
//

import Foundation
import Combine

/// ストリーミング接続状態
enum StreamingConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .disconnected:
            return "切断"
        case .connecting:
            return "接続中..."
        case .connected:
            return "接続済み"
        case .reconnecting(let attempt):
            return "再接続中 (\(attempt))"
        case .error(let message):
            return "エラー: \(message)"
        }
    }
}

/// ストリーミング設定
struct StreamingConfiguration: Codable, Equatable {
    /// サーバーURL
    var serverURL: String = "ws://localhost:8080/stream"
    /// 自動再接続を有効にする
    var autoReconnect: Bool = true
    /// 最大再接続試行回数
    var maxReconnectAttempts: Int = 5
    /// 再接続間隔（秒）
    var reconnectInterval: TimeInterval = 2.0
    /// バッファサイズ（フレーム数）
    var bufferSize: Int = 100
    /// 送信間隔（秒、0で毎フレーム）
    var sendInterval: TimeInterval = 0.0

    static let `default` = StreamingConfiguration()
}

/// WebSocketストリーミングクライアント
final class StreamingClient: ObservableObject {
    // MARK: - Published state
    @Published private(set) var connectionState: StreamingConnectionState = .disconnected
    @Published private(set) var sentFrameCount: UInt64 = 0
    @Published private(set) var droppedFrameCount: UInt64 = 0
    @Published private(set) var bytesSent: Int64 = 0
    @Published var configuration = StreamingConfiguration.default

    // MARK: - Private properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var sendTimer: Timer?
    private var lastSendTime: Date?

    private var frameBuffer: [SensorFrame] = []
    private let bufferQueue = DispatchQueue(label: "com.datastreaming.buffer", qos: .userInitiated)

    private var isRunning = false

    // MARK: - Initialization

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config)
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    /// サーバーに接続
    func connect() {
        guard !connectionState.isConnected else { return }

        guard let url = URL(string: configuration.serverURL) else {
            connectionState = .error("Invalid URL")
            return
        }

        connectionState = .connecting
        reconnectAttempt = 0
        isRunning = true

        createWebSocket(url: url)
    }

    /// サーバーから切断
    func disconnect() {
        isRunning = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        sendTimer?.invalidate()
        sendTimer = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        bufferQueue.sync {
            frameBuffer.removeAll()
        }

        connectionState = .disconnected
    }

    /// フレームを送信キューに追加
    func enqueueFrame(_ frame: SensorFrame) {
        bufferQueue.async { [weak self] in
            guard let self else { return }

            // バッファサイズを超えた場合は古いフレームを削除
            if self.frameBuffer.count >= self.configuration.bufferSize {
                self.frameBuffer.removeFirst()
                DispatchQueue.main.async {
                    self.droppedFrameCount += 1
                }
            }

            self.frameBuffer.append(frame)
        }

        // 送信間隔が0の場合は即座に送信
        if configuration.sendInterval == 0 {
            sendNextFrame()
        }
    }

    // MARK: - Private Methods

    private func createWebSocket(url: URL) {
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        receiveMessage()
        sendPing()

        connectionState = .connected

        // 送信間隔タイマーを設定
        if configuration.sendInterval > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.sendTimer = Timer.scheduledTimer(withTimeInterval: self?.configuration.sendInterval ?? 1.0, repeats: true) { [weak self] _ in
                    self?.sendNextFrame()
                }
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self, self.isRunning else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                self.handleDisconnection(error: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            // サーバーからのテキストメッセージを処理
            print("Received: \(text)")

        case .data(let data):
            // サーバーからのバイナリメッセージを処理
            print("Received data: \(data.count) bytes")

        @unknown default:
            break
        }
    }

    private func handleDisconnection(error: Error) {
        guard isRunning else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.webSocketTask = nil

            if self.configuration.autoReconnect && self.reconnectAttempt < self.configuration.maxReconnectAttempts {
                self.reconnectAttempt += 1
                self.connectionState = .reconnecting(attempt: self.reconnectAttempt)
                self.scheduleReconnect()
            } else {
                self.connectionState = .error(error.localizedDescription)
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: configuration.reconnectInterval, repeats: false) { [weak self] _ in
            guard let self, let url = URL(string: self.configuration.serverURL) else { return }
            self.createWebSocket(url: url)
        }
    }

    private func sendPing() {
        webSocketTask?.sendPing { [weak self] error in
            guard let self, self.isRunning else { return }

            if let error {
                self.handleDisconnection(error: error)
            } else {
                // 30秒後に次のpingを送信
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.sendPing()
                }
            }
        }
    }

    private func sendNextFrame() {
        guard connectionState.isConnected else { return }

        bufferQueue.async { [weak self] in
            guard let self, !self.frameBuffer.isEmpty else { return }

            let frame = self.frameBuffer.removeFirst()

            do {
                let data = try frame.toJSON()
                let message = URLSessionWebSocketTask.Message.data(data)

                self.webSocketTask?.send(message) { [weak self] error in
                    guard let self else { return }

                    if let error {
                        // エラー時はフレームをバッファに戻す
                        self.bufferQueue.async {
                            self.frameBuffer.insert(frame, at: 0)
                        }
                        print("Send error: \(error.localizedDescription)")
                    } else {
                        DispatchQueue.main.async {
                            self.sentFrameCount += 1
                            self.bytesSent += Int64(data.count)
                        }
                    }
                }
            } catch {
                print("Encoding error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Statistics

    /// 統計情報をリセット
    func resetStatistics() {
        sentFrameCount = 0
        droppedFrameCount = 0
        bytesSent = 0
    }

    /// バッファ内のフレーム数
    var bufferedFrameCount: Int {
        var count = 0
        bufferQueue.sync {
            count = frameBuffer.count
        }
        return count
    }

    /// 送信済みバイト数のフォーマット済み文字列
    var formattedBytesSent: String {
        ByteCountFormatter.string(fromByteCount: bytesSent, countStyle: .file)
    }
}

// MARK: - Streaming Settings View

import SwiftUI

struct StreamingSettingsView: View {
    @ObservedObject var client: StreamingClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("サーバー") {
                    TextField("URL", text: $client.configuration.serverURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section("接続") {
                    Toggle("自動再接続", isOn: $client.configuration.autoReconnect)

                    if client.configuration.autoReconnect {
                        Stepper(
                            "最大再接続回数: \(client.configuration.maxReconnectAttempts)",
                            value: $client.configuration.maxReconnectAttempts,
                            in: 1...10
                        )

                        HStack {
                            Text("再接続間隔")
                            Spacer()
                            Text("\(client.configuration.reconnectInterval, specifier: "%.1f")秒")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $client.configuration.reconnectInterval,
                            in: 0.5...10.0,
                            step: 0.5
                        )
                    }
                }

                Section("バッファ") {
                    Stepper(
                        "バッファサイズ: \(client.configuration.bufferSize)",
                        value: $client.configuration.bufferSize,
                        in: 10...1000,
                        step: 10
                    )

                    HStack {
                        Text("送信間隔")
                        Spacer()
                        if client.configuration.sendInterval == 0 {
                            Text("毎フレーム")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(client.configuration.sendInterval, specifier: "%.2f")秒")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Slider(
                        value: $client.configuration.sendInterval,
                        in: 0...1.0,
                        step: 0.05
                    )
                }

                Section {
                    Button("デフォルトに戻す") {
                        client.configuration = .default
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("ストリーミング設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Streaming Status View

struct StreamingStatusView: View {
    @ObservedObject var client: StreamingClient
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            // 接続状態
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(client.connectionState.description)
                    .font(.caption)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                        .font(.caption)
                }
            }

            // 統計情報
            if client.connectionState.isConnected {
                HStack(spacing: 12) {
                    Label("\(client.sentFrameCount)", systemImage: "arrow.up.circle")
                    Label("\(client.droppedFrameCount)", systemImage: "xmark.circle")
                    Label(client.formattedBytesSent, systemImage: "arrow.up.doc")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // 接続/切断ボタン
            Button {
                if client.connectionState.isConnected {
                    client.disconnect()
                } else {
                    client.connect()
                }
            } label: {
                Text(client.connectionState.isConnected ? "切断" : "接続")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(client.connectionState.isConnected ? .red : .blue)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showSettings) {
            StreamingSettingsView(client: client)
        }
    }

    private var statusColor: Color {
        switch client.connectionState {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
}

#Preview {
    VStack {
        StreamingStatusView(client: StreamingClient())
    }
    .padding()
}
