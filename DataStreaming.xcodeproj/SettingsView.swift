import SwiftUI

struct SettingsView: View {
    @AppStorage("signalingURLString") private var signalingURLString: String = "https://example.com"
    @AppStorage("useWebRTC") private var useWebRTC: Bool = true
    @AppStorage("serverBaseURLString") private var serverBaseURLString: String = "http://localhost:8080"
    
    private let defaultSignalingURLString = "https://example.com"
    private let defaultUseWebRTC = true
    private let defaultServerBaseURLString = "http://localhost:8080"
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Connectivity")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Signaling URL", text: $signalingURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if URL(string: signalingURLString) == nil {
                            Text("Invalid URL")
                                .foregroundColor(.red)
                                .font(.footnote)
                        }
                    }
                    
                    Toggle("Use WebRTC", isOn: $useWebRTC)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("REST Base URL", text: $serverBaseURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if URL(string: serverBaseURLString) == nil {
                            Text("Invalid URL")
                                .foregroundColor(.red)
                                .font(.footnote)
                        }
                    }
                }
                
                Section(header: Text("Actions")) {
                    Button("Reset to Defaults") {
                        signalingURLString = defaultSignalingURLString
                        useWebRTC = defaultUseWebRTC
                        serverBaseURLString = defaultServerBaseURLString
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
