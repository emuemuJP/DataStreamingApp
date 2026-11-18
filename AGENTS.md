# Repository Guidelines

## Project Structure & Module Organization

- `DataStreaming.xcodeproj` holds the Xcode project and scheme definitions.
- `DataStreaming/` contains the SwiftUI app sources (e.g., `ContentView.swift`, `AppDelegate.swift`).
- `DataStreaming/Assets.xcassets` stores app icons and color assets.
- No test target or standalone modules are present yet.

## Build, Test, and Development Commands

- Open the project: `open DataStreaming.xcodeproj`
- Build from CLI (example): `xcodebuild -scheme DataStreaming -destination 'platform=iOS Simulator,name=iPhone 15' build`
- Run in Simulator: use Xcode’s Run button with the `DataStreaming` scheme.
- Tests: no test target currently. If added, use `xcodebuild test` with the same scheme/destination.

## Coding Style & Naming Conventions

- Language: Swift/SwiftUI. Follow Swift API Design Guidelines and Xcode defaults.
- Indentation: 4 spaces; keep lines concise and prefer descriptive, camelCase names.
- Views: SwiftUI view structs should end with `View` where appropriate (e.g., `ContentView`).
- No linting or formatting tools are configured; avoid adding new dependencies without discussion.

## Testing Guidelines

- There are no tests in this repository yet.
- If introducing tests, use XCTest and a `DataStreamingTests` target with files named `*Tests.swift`.
- Keep tests small and deterministic; document any required simulator or OS version.

## Commit & Pull Request Guidelines

- Git history is minimal (`Initial Commit`), so no enforced convention exists.
- Use short, imperative commit messages (e.g., “Add streaming view state”).
- PRs should include: a concise summary, testing steps, and screenshots for UI changes.
- Link related issues or tasks when applicable.

## Security & Configuration Tips

- Keep secrets out of the repo; use environment variables or local Xcode configuration files.
- If adding config files, document them here and provide a safe default template.
