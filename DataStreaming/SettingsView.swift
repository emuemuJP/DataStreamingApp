//
//  SettingsView.swift
//  DataStreaming
//
//  Created by Claude on 2026/01/09.
//

import SwiftUI

struct SettingsView: View {
    @Binding var settings: RecordingSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("IMU設定") {
                    HStack {
                        Text("サンプリングレート")
                        Spacer()
                        Text("\(Int(settings.imuSamplingRate)) Hz")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $settings.imuSamplingRate,
                        in: 10...200,
                        step: 10
                    ) {
                        Text("サンプリングレート")
                    } minimumValueLabel: {
                        Text("10")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("200")
                            .font(.caption)
                    }
                }

                Section("ポイントクラウド設定") {
                    HStack {
                        Text("ダウンサンプリング")
                        Spacer()
                        Text("1/\(settings.pointCloudDownsample)")
                            .foregroundStyle(.secondary)
                    }
                    Picker("ダウンサンプリング係数", selection: $settings.pointCloudDownsample) {
                        Text("1 (最高解像度)").tag(1)
                        Text("2").tag(2)
                        Text("4 (標準)").tag(4)
                        Text("8 (高速)").tag(8)
                    }
                    .pickerStyle(.segmented)

                    Toggle("ポイントクラウドを録画", isOn: $settings.recordPointCloud)
                }

                Section("センサー有効化") {
                    Toggle("深度センシング", isOn: $settings.enableDepth)
                    Toggle("位置情報", isOn: $settings.enableLocation)
                }

                Section {
                    Button("デフォルトに戻す") {
                        settings = .default
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("設定")
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

#Preview {
    SettingsView(settings: .constant(.default))
}
