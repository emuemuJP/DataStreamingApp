const wrtc = require("wrtc");

const DEFAULT_URL = "http://localhost:8080/webrtc/sdp";
const SENSOR_TYPES = {
    video: 0,
    pointcloud: 1,
    imu: 2,
    location: 3,
};

function waitForIceGatheringComplete(pc, timeoutMs = 5000) {
    if (pc.iceGatheringState === "complete") {
        return Promise.resolve();
    }
    return new Promise((resolve) => {
        const onStateChange = () => {
            if (pc.iceGatheringState === "complete") {
                pc.removeEventListener("icegatheringstatechange", onStateChange);
                resolve();
            }
        };
        pc.addEventListener("icegatheringstatechange", onStateChange);
        setTimeout(() => resolve(), timeoutMs);
    });
}

function buildPacket(sensorType, sequence, payload) {
    const header = Buffer.alloc(24);
    header.writeUInt32LE(0x44535452, 0);
    header.writeUInt8(1, 4);
    header.writeUInt8(sensorType, 5);
    header.writeUInt16LE(0, 6);
    const timestampNanos = BigInt(Date.now()) * 1000000n;
    header.writeBigUInt64LE(timestampNanos, 8);
    header.writeUInt32LE(sequence, 16);
    header.writeUInt32LE(payload.length, 20);
    return Buffer.concat([header, payload]);
}

function samplePayload(sensorType) {
    if (sensorType === SENSOR_TYPES.video) {
        return Buffer.from([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x80, 0x1e]);
    }
    if (sensorType === SENSOR_TYPES.pointcloud) {
        const payload = Buffer.alloc(16);
        payload.writeUInt32LE(3, 0);
        return payload;
    }
    if (sensorType === SENSOR_TYPES.imu) {
        return Buffer.from([0x01, 0x02, 0x03, 0x04]);
    }
    return Buffer.from([0xaa, 0xbb, 0xcc, 0xdd]);
}

async function main() {
    const kind = (process.argv[2] || "video").toLowerCase();
    const sensorType = SENSOR_TYPES[kind] ?? SENSOR_TYPES.video;
    const url = process.env.WEBRTC_URL || DEFAULT_URL;

    const pc = new wrtc.RTCPeerConnection({
        iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });

    const channel = pc.createDataChannel("data");
    channel.binaryType = "arraybuffer";
    channel.addEventListener("open", () => {
        const payload = samplePayload(sensorType);
        const packet = buildPacket(sensorType, 1, payload);
        channel.send(packet);
        console.log(`[client] sent packet sensor=${kind} bytes=${packet.length}`);
        setTimeout(() => pc.close(), 500);
    });

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await waitForIceGatheringComplete(pc);

    const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            type: "offer",
            sdp: pc.localDescription.sdp,
        }),
    });
    if (!res.ok) {
        throw new Error(`signaling failed: ${res.status}`);
    }
    const data = await res.json();
    await pc.setRemoteDescription(
        new wrtc.RTCSessionDescription({ type: "answer", sdp: data.sdp }),
    );
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
