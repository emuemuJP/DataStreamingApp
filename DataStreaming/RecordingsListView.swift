//
//  RecordingsListView.swift
//  DataStreaming
//
//  Created by Claude on 2026/01/09.
//

import SwiftUI

struct RecordingsListView: View {
    @StateObject private var recordingManager = RecordingManager()
    @State private var sessions: [RecordingSessionInfo] = []
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var selectedSession: RecordingSessionInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "録画なし",
                        systemImage: "externaldrive.badge.xmark",
                        description: Text("録画されたセッションはありません")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            Button {
                                selectedSession = session
                            } label: {
                                SessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteSession(session)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    shareSession(session)
                                } label: {
                                    Label("共有", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("録画一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        loadSessions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                loadSessions()
            }
            .alert("エラー", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
                    ShareSheet(url: url)
                }
            }
            .sheet(item: $selectedSession) { session in
                SessionDetailView(session: session)
            }
        }
    }

    private func loadSessions() {
        do {
            sessions = try recordingManager.listSessions()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteSession(_ session: RecordingSessionInfo) {
        do {
            try recordingManager.deleteSession(sessionId: session.sessionId)
            sessions.removeAll { $0.id == session.id }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func shareSession(_ session: RecordingSessionInfo) {
        shareURL = session.directoryURL
        showShareSheet = true
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: RecordingSessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.startTime, style: .date)
                    .font(.headline)
                Text(session.startTime, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label(session.formattedDuration, systemImage: "clock")
                Label("\(session.frameCount) frames", systemImage: "doc.text")
                Label(session.formattedFileSize, systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(session.sessionId)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: RecordingSessionInfo
    @State private var isExporting = false
    @State private var exportFormat: PointCloudFormat = .ply
    @State private var showExportSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var exportedURL: URL?
    @State private var showShareSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("セッション情報") {
                    LabeledContent("開始時刻") {
                        Text(session.startTime, style: .date)
                        Text(session.startTime, style: .time)
                    }

                    if let endTime = session.endTime {
                        LabeledContent("終了時刻") {
                            Text(endTime, style: .date)
                            Text(endTime, style: .time)
                        }
                    }

                    LabeledContent("録画時間", value: session.formattedDuration)
                    LabeledContent("フレーム数", value: "\(session.frameCount)")
                    LabeledContent("ファイルサイズ", value: session.formattedFileSize)
                }

                Section("セッションID") {
                    Text(session.sessionId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("ポイントクラウドエクスポート") {
                    Picker("形式", selection: $exportFormat) {
                        ForEach(PointCloudFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }

                    Button {
                        exportPointCloud()
                    } label: {
                        HStack {
                            Label("エクスポート", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting)
                }

                if let url = exportedURL {
                    Section("エクスポート済みファイル") {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label(url.lastPathComponent, systemImage: "doc")
                        }
                    }
                }
            }
            .navigationTitle("セッション詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
            .alert("エクスポート完了", isPresented: $showExportSuccess) {
                Button("共有") {
                    showShareSheet = true
                }
                Button("OK", role: .cancel) { }
            } message: {
                if let url = exportedURL {
                    Text("ファイルを保存しました:\n\(url.lastPathComponent)")
                }
            }
            .alert("エラー", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedURL {
                    ShareSheet(url: url)
                }
            }
        }
    }

    private func exportPointCloud() {
        isExporting = true

        Task {
            do {
                let url = try PointCloudExporter.exportFromSession(
                    sessionDir: session.directoryURL,
                    format: exportFormat,
                    aggregateAll: true
                )

                await MainActor.run {
                    exportedURL = url
                    isExporting = false
                    showExportSuccess = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                    showError = true
                }
            }
        }
    }
}

#Preview {
    RecordingsListView()
}
