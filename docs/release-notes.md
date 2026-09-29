Fourth release. Claude logins that stay logged in, and Codex only when it is.

**What changed since v0.1.2**

- Claude accounts can now be signed in from the Accounts window. A profile
  signed in this way owns its login and refreshes it over HTTP, so it never
  raises the macOS password prompt. Profiles added from an existing Claude Code
  login still work, but they mirror the CLI's session and ask for the Keychain
  password again whenever that session's token expires.
- Mirrored profiles no longer log the Claude Code CLI out. The app used to
  refresh their token itself, which rotated the refresh token out from under
  the CLI; they now wait for the CLI to refresh and pick up the new token. They
  also wait until the token has actually expired before re-reading it, which
  halves the password prompts.
- Codex shows up only when the Codex CLI is signed in to ChatGPT. Having the CLI
  installed was enough before, and the row showed stale limits from its local
  session files.
- The Accounts window no longer disappears when you click another app, and it
  opens in front instead of behind the frontmost window.

**Installing.** Open the `.dmg` and drag AI Usage to Applications. The build is
ad-hoc signed rather than notarized, so macOS will refuse it on first launch:
open **System Settings → Privacy & Security** and press **Open Anyway**, or run
`xattr -d com.apple.quarantine "/Applications/AI Usage.app"`. The warning is
accurate — nobody has vouched for this binary. Building from source takes a
couple of minutes and signs it locally with your own Apple ID.

**What's in it**

- Claude (multiple accounts), Codex and Cursor, collected natively — no Python,
  no helper processes
- Menu bar panel with session and weekly meters and renewal countdowns
- Widgets in all three sizes
- Claude sign-in from the Accounts window, or registration from the Claude Code
  logins already on the machine; Codex comes from the Codex CLI's own login
- Notifications as a limit crosses each configured threshold

**Known issue.** The app icon does not appear in the widget gallery. Cosmetic;
see PLAN.md for what has been ruled out.
