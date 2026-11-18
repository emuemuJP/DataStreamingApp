import Foundation

#if canImport(WebRTC)
import WebRTC
#endif

final class WebRTCTransport: Transport {
    // Public API
    init(signalingURL: URL) {
        self.signalingURL = signalingURL
        #if canImport(WebRTC)
        self.factory = RTCPeerConnectionFactory()
        #endif
    }

    func start() {
        #if canImport(WebRTC)
        setupPeer()
        createOffer()
        #else
        print("[WebRTCTransport] WebRTC framework not available, running as no-op")
        #endif
    }

    func close() {
        #if canImport(WebRTC)
        dataChannel?.close()
        peer?.close()
        #endif
    }

    // Transport
    func send(sensor: SensorType, timestampNanos: UInt64, sequence: UInt32, payload: Data) {
        #if canImport(WebRTC)
        guard let dc = dataChannel else { return }
        var header = PacketHeader(sensor: sensor, timestampNanos: timestampNanos, sequence: sequence, payloadLength: UInt32(payload.count)).encode()
        var body = Data()
        body.append(header)
        body.append(payload)
        let buffer = RTCDataBuffer(data: body, isBinary: true)
        dc.sendData(buffer)
        #else
        // no-op
        #endif
    }

    // MARK: - Private
    private let signalingURL: URL
    #if canImport(WebRTC)
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?

    private func setupPeer() {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]) ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]) 
        peer = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        dataChannel = peer?.dataChannel(forLabel: "data", configuration: dcConfig)
        dataChannel?.delegate = self
    }

    private func createOffer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer?.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp = sdp else { print("offer error: \(String(describing: error))"); return }
            self.peer?.setLocalDescription(sdp, completionHandler: { err in
                if let err = err { print("setLocalDescription error: \(err)") }
            })
            self.postSDP(type: "offer", sdp: sdp.sdp) { answer in
                guard let answer = answer else { return }
                let remote = RTCSessionDescription(type: .answer, sdp: answer)
                self.peer?.setRemoteDescription(remote, completionHandler: { err in
                    if let err = err { print("setRemoteDescription error: \(err)") }
                })
            }
        }
    }

    private func postSDP(type: String, sdp: String, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: signalingURL.appendingPathComponent("/webrtc/sdp"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = ["type": type, "sdp": sdp]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { completion(nil); return }
            completion(obj["sdp"])
        }.resume()
    }
    #endif
}

#if canImport(WebRTC)
extension WebRTCTransport: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // TODO: send ICE to signaling server
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }
}

extension WebRTCTransport: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[WebRTC] DataChannel state: \(dataChannel.readyState.rawValue)")
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        print("[WebRTC] Received \(buffer.data.count) bytes")
    }
}
#endif

#if !canImport(WebRTC)
extension WebRTCTransport {
    func start() {
        print("[WebRTCTransport] WebRTC framework not available, running as no-op")
    }
    func close() {}
    func send(sensor: SensorType, timestampNanos: UInt64, sequence: UInt32, payload: Data) {}
}
#endif
