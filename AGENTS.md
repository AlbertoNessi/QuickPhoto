# AGENTS.md
Guidance for coding agents working in `QuickPhoto`.

## Repository Overview
- Platform: macOS only.
- Languages: Objective-C, Swift, zsh.
- Primary shipping path today: `Sources/QuickPhotoObjC/main.m` via `./qp`.
- Hotkey helper path: `Sources/QPHotkey/main.m` via `./qp-hotkey`.
- SwiftPM exists in `Package.swift`, with a Swift implementation in `Sources/QuickPhoto/QuickPhoto.swift`.
- No third-party dependencies are used; prefer Apple frameworks only.

## External Agent Rules
- No `.cursorrules` file was found.
- No files were found under `.cursor/rules/`.
- No `.github/copilot-instructions.md` file was found.
- If any of those files appear later, treat them as higher-priority guidance and update this file.

## Important Paths
- `qp` - zsh launcher that compiles and runs the Objective-C capture tool.
- `qp-hotkey` - zsh launcher that compiles and runs the hotkey helper.
- `install-qp-hotkey` - installs the LaunchAgent plist.
- `uninstall-qp-hotkey` - removes the LaunchAgent plist.
- `Sources/QuickPhotoObjC/main.m` - main capture, preview, clipboard, and CLI behavior.
- `Sources/QPHotkey/main.m` - global hotkey registration and capture triggering.
- `Sources/QuickPhoto/QuickPhoto.swift` - Swift implementation/prototype.
- `README.md` - setup, usage, permissions, and troubleshooting.

## Build Commands
Use the launcher scripts first; they match how the repo is intended to run.
Main tool build/run:
```bash
./qp --help
```
Hotkey helper build/run:
```bash
./qp-hotkey --help
```
Manual Objective-C compile for the main tool:
```bash
clang -fobjc-arc Sources/QuickPhotoObjC/main.m -o .build/qp -framework Foundation -framework AppKit -framework CoreImage -framework CoreMedia -framework CoreVideo -framework AVFoundation
```
Manual Objective-C compile for the hotkey helper:
```bash
clang -fobjc-arc Sources/QPHotkey/main.m -o .build/qp-hotkey -framework Foundation -framework AppKit -framework Carbon
```
Secondary SwiftPM entrypoint:
```bash
swift build
```
- Prefer the scripts over `swift build`.
- In the current environment, `swift build` failed while linking the manifest; verify locally before depending on SwiftPM automation.

## Lint And Formatting Commands
- No repo-local linter or formatter config was found (`.swiftlint.yml`, `.clang-format`, `.editorconfig`, `swiftformat`, and `Makefile` were absent).
- There is no checked-in `lint` command.
- There is no checked-in `format` command.
- Use compiler feedback and manual formatting that matches surrounding code.
- If you add linting or formatting, document the exact command here.

## Test Commands
There is currently no `Tests/` directory and no automated test target.
Current verification commands:
```bash
./qp --camera-list
./qp --headless --save /tmp/qp-capture.jpg
./qp-hotkey --self-test-hotkey
```
Useful manual runs:
```bash
./qp
./qp --delay 1 --save /tmp/qp-capture.jpg
./qp-hotkey --run-once
```
SwiftPM test entrypoint once tests are added:
```bash
swift test
```
Run a single test case once tests exist:
```bash
swift test --filter 'QuickPhotoTests/testExample'
```
Run one test suite once tests exist:
```bash
swift test --filter 'QuickPhotoTests'
```
- If you add tests, prefer SwiftPM tests under `Tests/`.
- After capture-flow changes, run at least one headless capture path and one help or diagnostics path.
- After hotkey changes, run `./qp-hotkey --self-test-hotkey` and, if safe, `./qp-hotkey --run-once`.

## Change Priorities
- Preserve the current no-dependency, native-macOS approach.
- Prefer small edits inside the existing Objective-C flow over broad rewrites.
- Keep CLI behavior deterministic and script-friendly.
- Maintain manual usability: preview mode, clear stderr errors, and straightforward help output.

## Code Style: General
- Match the language already used in the file; do not migrate Objective-C to Swift or the reverse unless asked.
- Keep changes local and incremental.
- Prefer straightforward control flow over abstraction-heavy designs.
- Use early returns and guard-style exits to keep the happy path readable.
- Keep user-visible strings concise and actionable.
- Avoid adding dependencies, wrappers, or utility layers without clear payoff.

## Imports
- Import only the frameworks actually used by the file.
- Keep imports grouped at the top of the file.
- Preserve the deterministic ordering already present instead of reordering aggressively.
- In Objective-C, keep explicit framework imports like `#import <AppKit/AppKit.h>`.
- In Swift, use direct `import` statements and match existing order.

## Formatting
- Swift uses 4-space indentation.
- Objective-C in this repo uses 2-space indentation.
- Match nearby brace placement and declaration layout.
- Do not introduce trailing whitespace.
- Preserve readable line breaks for long Objective-C method signatures, conditionals, and dictionary literals.
- Split long sections before they become hard to scan.

## Types And APIs
- Prefer concrete Apple framework types over wrappers.
- In Swift, use `struct`, `enum`, and `final class` when they fit existing patterns.
- In Objective-C, keep file-local helpers as `static` C functions when object state is unnecessary.
- Use enums for modes or error categories instead of loose integers when the file already models that concept.
- Keep APIs small; most behavior in this repo is internal to executables.

## Naming
- Swift types use UpperCamelCase.
- Swift properties, methods, and enum cases use lowerCamelCase.
- Objective-C classes use the `QP` prefix.
- Objective-C file-local functions and constants also use the `QP` prefix.
- Choose names that describe user-visible behavior, not generic utility concepts.
- Keep command-line option names stable unless the task explicitly changes the CLI contract.

## Error Handling
- Surface actionable errors to stderr.
- In Swift, prefer typed errors such as `QuickPhotoError` and convert low-level failures into readable messages.
- In Objective-C, follow the existing `NSError **errorOut` pattern for fallible helpers.
- Return early when preconditions fail.
- Include enough context to debug permissions, device selection, configuration, launch, timeout, or clipboard failures.
- Preserve existing exit-code behavior unless there is a strong reason to change it.
- Keep cancellation non-fatal when that matches current behavior.

## Logging, Concurrency, And Behavior
- Use stdout for normal status/help text and stderr for failures or warnings.
- Keep success output short; these tools are CLI-driven.
- Do not leave noisy debug logging enabled.
- Be careful with capture-session lifecycle; always stop sessions on exit paths.
- Preserve semaphore and run-loop coordination unless you are replacing the whole flow deliberately.
- Keep hotkey-triggered capture serialized; overlapping capture is intentionally prevented.
- When dealing with permissions or device warm-up, prefer deterministic waits with clear timeout behavior.

## Shell Script Style
- Keep zsh scripts executable and simple.
- Continue using `set -euo pipefail` in repository scripts.
- Resolve script-relative paths from `SCRIPT_DIR` instead of assuming the caller's working directory.
- Prefer idempotent install/uninstall behavior for LaunchAgent scripts.

## Documentation Expectations
- Update `README.md` when changing CLI flags, install flow, permissions, or hotkey behavior.
- Update this `AGENTS.md` when build, lint, test, or style expectations change.
- Document new verification commands if you add new entrypoints.

## Before Finishing A Change
- Re-read touched files and match local style exactly.
- Run the most relevant script-based verification command you can safely run.
- Mention environment-specific limits you hit, especially camera permissions or SwiftPM manifest issues.
- Do not claim automated tests passed when the repo has no tests.
