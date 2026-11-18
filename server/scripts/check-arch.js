if (process.arch === "arm64") {
    console.error(
        [
            "",
            "wrtc prebuilt binaries are not available for darwin-arm64.",
            "Use x64 Node under Rosetta to install the darwin-x64 prebuilt:",
            "",
            "  arch -x86_64 zsh -lc \"nvm install 20 --arch=x64\"",
            "  arch -x86_64 zsh -lc \"nvm use 20\"",
            "  arch -x86_64 zsh -lc \"npm run setup\"",
            "",
            "If you want native arm64, you must build from source with full depot_tools.",
            "",
        ].join("\n"),
    );
    process.exit(1);
}
