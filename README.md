# ClaudeUsageBar

macOS menu bar app that shows Claude Code subscription rate-limit utilization — the 5-hour session, 7-day weekly, and per-model weekly buckets reported by Anthropic's usage endpoint — for up to **two accounts**. Requires a logged-in Claude CLI: the app reads the `Claude Code-credentials` Keychain items the CLI manages (including the hash-suffixed items created per `CLAUDE_CONFIG_DIR` profile).

With one account, the bar shows a compact single line of percentages (`34·21·8` = 5h · 7d · per-model weekly), each number colored green / orange (≥50%) / red (≥80%). With a second account assigned, the bar stacks two small rows, prefixed `P` and `W`. The dropdown menu shows the full breakdown per account with reset times, plus an **Accounts** submenu that lists every detected credential item so you can choose which item is P and which is W (saved in preferences). Usage polls every 5 minutes; when rate-limited, the last-known numbers stay up with a ⧖ stale marker.

## Credential handling

The app doesn't just read the Keychain item — when an account's access token is expired (or rejected), it refreshes it against `https://claude.ai/v1/oauth/token` using Claude Code's public OAuth client ID, then **writes the new tokens back into that account's shared Keychain item** so the CLI and this app stay in sync. Write-back preserves the rest of the stored JSON (e.g. `mcpOAuth`, scopes).

Keychain reads and writes shell out to `/usr/bin/security` rather than using Security.framework, because the CLI creates the item with an ACL that only allows `security` to decrypt it. This is also why the app sandbox is disabled in the entitlements.

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

### Xcode project configuration

The project is already configured for this identity — `ClaudeUsageBar.xcodeproj/project.pbxproj` has both occurrences of

```
CODE_SIGN_IDENTITY = "Matt Green Code Signing";
```

so the build fails until a cert with that exact name exists in your login keychain. Either create it as above, or if you named your cert differently, update both occurrences to match (or set them to `"-"` for an ad-hoc build, at the cost of the Keychain re-prompts described earlier).

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

The approval is per Keychain item, so assigning a second account in the **Accounts** submenu triggers one more dialog for that account's item — click **Always Allow** there too.

If the cert is ever regenerated (e.g. after macOS reinstall), the approval must be granted once more.
