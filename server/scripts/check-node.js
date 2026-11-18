const major = Number(process.versions.node.split(".")[0]);

if (Number.isNaN(major)) {
    process.exit(0);
}

if (major >= 23) {
    console.error(
        [
            "",
            "wrtc prebuilt binaries are not available for Node.js 23+ on darwin-arm64.",
            "Please use Node.js 20 or 18 (LTS) and retry.",
            "",
            "Example (nvm):",
            "  nvm install 20",
            "  nvm use 20",
            "",
        ].join("\n"),
    );
    process.exit(1);
}
