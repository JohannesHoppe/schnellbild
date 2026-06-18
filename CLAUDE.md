# Working notes — Schnellbild

## Verify heavy / UI changes on CI, not locally

Local runs of the app, XCUITests, code-signing, or `sudo` steps pop macOS
**system dialogs** (Gatekeeper, Touch ID / LocalAuthentication, license prompts)
that interrupt the user. For complex or risky changes, **prefer pushing and
verifying on CI** (push → watch the run) over launching or UI-testing locally.

- **Fine locally** (no popups): `./Scripts/test.sh` (unit tests), `swift build`.
- **Prefer CI** (avoids local popups): running the `.app`, XCUITest,
  `Scripts/build_app.sh`, anything that signs or launches a freshly-built bundle.
- Only fall back to local launches/UI runs when CI genuinely can't answer the
  question — and say so first.
