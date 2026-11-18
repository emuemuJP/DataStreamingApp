# WebRTC PoC Server

Minimal Node.js + Express + wrtc WebRTC signaling and DataChannel receiver.

## Setup

```bash
nvm install
nvm use
npm init -y
npm run setup
node server.js
```

## Docker (x64 on Apple Silicon)

If you want to avoid native installs, run the server in an x64 Linux container:

```bash
docker build --platform=linux/amd64 -t webrtc-poc-server .
docker run --platform=linux/amd64 -p 8080:8080 webrtc-poc-server
```

### Apple Silicon note

`wrtc` does not publish darwin-arm64 prebuilts. The easiest path is to install
an x64 Node under Rosetta and let `npm` download the darwin-x64 binary:

```bash
arch -x86_64 zsh -lc "nvm install 20 --arch=x64"
arch -x86_64 zsh -lc "nvm use 20"
arch -x86_64 zsh -lc "npm run setup"
```

If `wrtc` fails to download prebuilt binaries, the setup script falls back to:

```bash
npm i wrtc --build-from-source
```

Build-from-source prerequisites on macOS:

```bash
xcode-select --install
brew install cmake
```

If build-from-source still fails, try installing from the upstream GitHub repo:

```bash
npm i github:node-webrtc/node-webrtc
```

## Endpoints

- `POST /webrtc/sdp`
  - JSON body: `{ "type": "offer", "sdp": "<SDP文字列>" }`
  - Response: `{ "sdp": "<answer.sdp>" }`
  - Non-trickle ICE (waits for gathering completion).
- `POST /ingest/video`
- `POST /ingest/pointcloud`
- `POST /ingest/imu`
- `POST /ingest/location`

## Logs (examples)

- `webrtc PoC server listening on http://0.0.0.0:8080`
- `[webrtc] type=offer sdp-len=...`
- `[webrtc] datachannel opened: data`
- `[packet] sensor=video seq=123 ts=... bytes=...`

## Quick signaling test (curl)

You need a valid SDP offer. If you already have one, send it like this:

```bash
curl -X POST http://localhost:8080/webrtc/sdp \
  -H "Content-Type: application/json" \
  -d '{"type":"offer","sdp":"<SDP文字列>"}'
```

## DataChannel sender sample (Node.js)

Requires `wrtc`. On Apple Silicon, run this in Docker.

```bash
node client/send.js video
```

### Run sender in Docker

If the server is running on your host or mapped via `-p 8080:8080`:

```bash
docker run --platform=linux/amd64 --rm \
  -e WEBRTC_URL="http://host.docker.internal:8080/webrtc/sdp" \
  webrtc-poc-server node client/send.js video
```
