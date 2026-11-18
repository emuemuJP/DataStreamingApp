const express = require("express");
const wrtc = require("wrtc");

const app = express();
const PORT = process.env.PORT || 8080;

app.use(express.json({ limit: "2mb" }));

const HEADER_SIZE = 24;
const MAGIC = 0x44535452; // "DSTR"

function parsePacket(buffer) {
    if (!Buffer.isBuffer(buffer)) {
        buffer = Buffer.from(buffer);
    }
    if (buffer.length < HEADER_SIZE) {
        return { error: "packet too short" };
    }

    const magic = buffer.readUInt32LE(0);
    const version = buffer.readUInt8(4);
    const sensorType = buffer.readUInt8(5);
    const timestampNanos = buffer.readBigUInt64LE(8);
    const sequence = buffer.readUInt32LE(16);
    const payloadLength = buffer.readUInt32LE(20);
    const payload = buffer.slice(HEADER_SIZE);

    if (magic !== MAGIC || version !== 1) {
        return {
            error: "invalid header",
            magic,
            version,
            sensorType,
            timestampNanos,
            sequence,
            payloadLength,
            payload,
        };
    }

    return {
        magic,
        version,
        sensorType,
        timestampNanos,
        sequence,
        payloadLength,
        payload,
    };
}

function sensorName(sensorType) {
    switch (sensorType) {
        case 0:
            return "video";
        case 1:
            return "pointCloud";
        case 2:
            return "imu";
        case 3:
            return "location";
        default:
            return `unknown(${sensorType})`;
    }
}

function logPacket(packet) {
    if (packet.error) {
        console.warn(`[packet] ${packet.error}`);
        return;
    }

    const sensor = sensorName(packet.sensorType);
    const ts = packet.timestampNanos.toString();
    const bytes = packet.payload.length;

    console.log(
        `[packet] sensor=${sensor} seq=${packet.sequence} ts=${ts} bytes=${bytes}`,
    );

    if (sensor === "video" && bytes > 0) {
        const head = packet.payload.slice(0, 16).toString("hex");
        console.log(`[packet] video head=${head}`);
    }
    if (sensor === "pointCloud" && bytes >= 4) {
        const count = packet.payload.readUInt32LE(0);
        console.log(`[packet] pointCloud count=${count}`);
    }
}

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

app.post("/webrtc/sdp", async (req, res) => {
    const { type, sdp } = req.body || {};
    console.log(`[webrtc] type=${type} sdp-len=${sdp ? sdp.length : 0}`);

    if (type !== "offer" || !sdp) {
        res.status(400).json({ error: "invalid offer" });
        return;
    }

    const pc = new wrtc.RTCPeerConnection({
        iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });

    pc.addEventListener("datachannel", (event) => {
        const channel = event.channel;
        console.log(`[webrtc] datachannel opened: ${channel.label}`);
        channel.binaryType = "arraybuffer";
        channel.addEventListener("message", (msgEvent) => {
            const packet = parsePacket(Buffer.from(msgEvent.data));
            logPacket(packet);
        });
    });

    try {
        await pc.setRemoteDescription(
            new wrtc.RTCSessionDescription({ type, sdp }),
        );
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await waitForIceGatheringComplete(pc);

        res.json({ sdp: pc.localDescription.sdp });
    } catch (err) {
        console.error("[webrtc] error", err);
        res.status(500).json({ error: "webrtc failure" });
    }
});

function logIngest(kind, buffer) {
    const size = buffer.length;
    const head = buffer.slice(0, 16).toString("hex");
    console.log(`[ingest] ${kind} bytes=${size} head=${head}`);
}

app.post(
    "/ingest/video",
    express.raw({ type: "*/*", limit: "50mb" }),
    (req, res) => {
        logIngest("video", req.body);
        res.json({ ok: true });
    },
);

app.post(
    "/ingest/pointcloud",
    express.raw({ type: "*/*", limit: "50mb" }),
    (req, res) => {
        logIngest("pointcloud", req.body);
        res.json({ ok: true });
    },
);

app.post(
    "/ingest/imu",
    express.raw({ type: "*/*", limit: "50mb" }),
    (req, res) => {
        logIngest("imu", req.body);
        res.json({ ok: true });
    },
);

app.post(
    "/ingest/location",
    express.raw({ type: "*/*", limit: "50mb" }),
    (req, res) => {
        logIngest("location", req.body);
        res.json({ ok: true });
    },
);

app.listen(PORT, "0.0.0.0", () => {
    console.log(`webrtc PoC server listening on http://0.0.0.0:${PORT}`);
});
