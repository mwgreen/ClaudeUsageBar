# ClaudeUsageBar

macOS menu bar app that surfaces Claude API usage. Reads the `Claude Code-credentials` Keychain item managed by the Claude CLI.

## Build

```sh
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release -derivedDataPath build
cp -R build/Build/Products/Release/ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

## Code signing (recommended)

This project signs with a local self-signed code-signing certificate named `Matt Green Code Signing`. A stable signing identity matters because ClaudeUsageBar reads a Keychain item owned by another app (the Claude CLI): macOS prompts "ClaudeUsageBar wants to access 'Claude Code-credentials'" on first access, and you grant "Always Allow" once. That approval is keyed to the signing identity, so an ad-hoc (unsigned) binary re-prompts after every rebuild — and may re-prompt when the Claude CLI refreshes its Keychain item. A proper signature makes the approval persist.

### One-time setup: create a self-signed code signing certificate

1. Open **Keychain Access**.
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `Matt Green Code Signing` (or any name — if you change it, update the Xcode project to match)
   - **Identity Type:** **Self Signed Root**
   - **Certificate Type:** **Code Signing**
   - Tick **Let me override defaults**
4. Continue through the wizard. Set **Validity period** to `3650` days. Accept the other defaults.
5. Save to the **login** keychain.

Verify:

```sh
security find-certificate -c "Matt Green Code Signing" -p | openssl x509 -noout -subject
```

No `security add-trusted-cert` step is needed — the cert does not require an explicit user trust setting for code signing to work.

### Wire it into the Xcode project

In `ClaudeUsageBar.xcodeproj/project.pbxproj`, both occurrences of

```
CODE_SIGN_IDENTITY = "-";
```

should be

```
CODE_SIGN_IDENTITY = "Matt Green Code Signing";
```

Keep `CODE_SIGN_STYLE = Manual;` and do **not** set `DEVELOPMENT_TEAM`.

### Bundle layout

`Contents/MacOS/` must contain only Mach-O executables. Scripts, source, and other assets belong in `Contents/Resources/`. A stray non-binary file under `Contents/MacOS/` breaks the signature and defeats the Keychain "Always Allow" persistence.

### Rebuild and verify

```sh
pkill -x ClaudeUsageBar 2>/dev/null
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release -derivedDataPath build
rm -rf /Applications/ClaudeUsageBar.app
cp -R build/Build/Products/Release/ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app

codesign -dv --verbose=2 /Applications/ClaudeUsageBar.app 2>&1 | grep Authority
# Expect: Authority=Matt Green Code Signing
```

### First launch

macOS shows a Keychain dialog asking ClaudeUsageBar to access the `Claude Code-credentials` item. Click **Always Allow**. Subsequent launches and Claude CLI token refreshes won't re-prompt.

If the cert is ever regenerated (e.g. after macOS reinstall), the approval must be granted once more.
