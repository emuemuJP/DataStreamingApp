const { execSync } = require("node:child_process");

if (process.env.SKIP_CMAKE_CHECK === "1") {
    process.exit(0);
}

try {
    execSync("cmake --version", { stdio: "ignore" });
} catch (err) {
    console.error(
        [
            "",
            "CMake is required to build wrtc from source.",
            "Install it and retry:",
            "",
            "  brew install cmake",
            "",
        ].join("\n"),
    );
    process.exit(1);
}
