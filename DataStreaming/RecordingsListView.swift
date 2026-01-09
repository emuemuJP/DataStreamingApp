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
                            SessionRow(session: session)
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

#Preview {
    RecordingsListView()
}
