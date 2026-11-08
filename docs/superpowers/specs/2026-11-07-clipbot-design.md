# Clipbot — design

Date: 2026-11-07. Status: approved in conversation, pending builder check.

## Intent

Linus uses **Clipy** (clipy-app.com) every day as a clipboard history + snippets
tool. It works well, but it is a security liability: it keeps the last 100 clips
as **plain, unencrypted files** (`~/Library/Application Support/Clipy/*.data`,
mode 0644) readable by any process running as the user; it records passwords
copied from 1Password; and it phones home (Crashlytics, Sparkle update checks).

Clipbot is a from-scratch replacement that **feels identical to Clipy in daily
use** but is built safe: passwords are never captured, everything at rest is
encrypted, and nothing ever leaves the Mac.

Success = Linus deletes Clipy and doesn't notice a difference, except that his
clipboard history is no longer a place secrets go to die.

## Goals

1. Same muscle memory as Clipy (shortcuts, menu shape, paste behaviour).
2. Passwords from password managers are never stored — not on disk, not in the
   history, not in logs.
3. All persisted data (clips, index, snippets) encrypted at rest; useless if the
   folder is copied off the machine.
4. Zero network activity. No sync, analytics, crash reporting or update checks.
5. Carry over Linus's existing snippets.

## Non-goals

- iCloud/multi-device sync, sharing, cloud anything.
- Searchable/fuzzy-find UI, previews panel, pinning, Maccy-style window. (Possible
  later; not now.)
- Importing the existing 100 Clipy clips (unencrypted, may already contain
  passwords — start fresh).
- App Store distribution, auto-update, localisation.

## Anti-goals (failure even if it "works")

- A password copied from 1Password or Apple Passwords appears in the history or
  on disk, even briefly, even in a temp file.
- Any outbound network connection.
- Plaintext clip content anywhere on disk (including caches, logs, crash files).
- Noticeably slower or clunkier to use than Clipy.
- Third-party dependencies that widen the supply-chain surface of an app that
  sees everything Linus copies.

## Current Clipy setup being replaced (read from his prefs)

| Action | Shortcut |
|---|---|
| Main menu (history + snippets) | **⌘⇧V** |
| History-only menu | **⌃⌘V** |
| Snippets-only menu | **⌘⇧B** |

- Max history: 100. Stored types: plain text, RTF, RTFD, PDF, TIFF (images),
  file names, URL.
- Launch at login: on. Menu bar icon: **hidden**.

Snippets to migrate (3 folders, 6 snippets):

- **code** — "code cleanup", "consolidation"
- **Learning** — "Short", "Long"
- **cal** — "15m", "30m" (cal.com links)

## Behaviour (decided with Linus)

### The menu

⌘⇧V pops up a native `NSMenu` at the mouse cursor, over whatever app is in
front, like Clipy. Contents, top to bottom:

1. **History** — 10 submenus titled `1 - 10`, `11 - 20`, … `91 - 100`, each
   holding 10 clips, newest first. Text items show a single-line truncated
   preview (whitespace collapsed); images show a small thumbnail; files show the
   file name; other types show a type label. Inside a submenu, number keys
   `1`…`9`, `0` select the item (Clipy-style key equivalents). Empty groups are
   not shown.
2. Separator, **Snippets** — one submenu per folder (folder title), each listing
   its snippets by title. Disabled folders/snippets are hidden.
3. Separator, **Clear History…**, **Edit Snippets…**, **Settings…**, **Quit Clipbot**.

⌃⌘V shows the same menu with only section 1 (+ the bottom items).
⌘⇧B shows only section 2 (+ the bottom items).

### Selecting an item

The item's full original representations are put on the general pasteboard and
Clipbot immediately pastes into the previously frontmost app (synthesised ⌘V,
which needs Accessibility permission — requested once, like Clipy). The item
stays on the clipboard afterwards. A history item that is selected moves to the
top of history. Clipbot must not re-record its own pasteboard write as a new clip.

Without Accessibility permission, selecting still copies the item to the
clipboard; Clipbot shows a one-time explanation of how to grant permission.

### History rules

- Max 100 items. The 101st evicts the oldest (and deletes its encrypted file).
- Copying something identical to an existing item moves that item to the top
  instead of creating a duplicate.
- Empty / whitespace-only clips are ignored.
- Stored types: same as Clipy (text, RTF, RTFD, PDF, images, file URLs, URLs).
  All representations of those types on the pasteboard at copy time are kept so
  pasting reproduces the original fidelity.

### Clear History…

Asks for confirmation, then erases all clips (see crypto-shredding below).

### Edit Snippets…

A small window: folder list on the left, snippets on the right, editor for
title + content. Add, rename, reorder (drag), delete, enable/disable for folders
and snippets — Clipy's editor, nothing fancier. Changes save immediately
(encrypted). Includes **Import from Clipy XML…** (Clipy's own snippet export
format) for migration.

### Settings…

- The three shortcuts (recorder for each; defaults above).
- Launch at login (default on, via `SMAppService`).
- Accessibility permission status + button to open the right Settings pane.
- Clipboard-access permission status (see constraints).
- Ignored apps list (bundle IDs; pre-filled, see below), editable.
- Clear History button.

No menu bar icon. Re-opening Clipbot from Finder/Spotlight while running opens
Settings, so it is never unreachable.

## Security design

### 1. Never capture secrets (filter before anything else)

Every pasteboard change is evaluated **before** its contents are read into a
clip or written anywhere. A change is dropped entirely if any of:

- The pasteboard carries a marker type from the nspasteboard.org conventions:
  `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`,
  `org.nspasteboard.AutoGeneratedType`, or 1Password's legacy
  `com.agilebits.onepassword`. (This is the primary, reliable mechanism —
  1Password and Apple Passwords mark copies as concealed.)
- The frontmost app at the time of the change is on the ignored-apps list.
  Defaults: 1Password (`com.1password.1password`, `com.agilebits.onepassword7`),
  Apple Passwords (`com.apple.Passwords`), Keychain Access
  (`com.apple.keychainaccess`). User-editable.
- Plain text matches a well-known secret format (safety net; deliberately
  narrow to avoid false positives): OpenAI/Anthropic-style `sk-…` keys, GitHub
  tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), AWS access key
  IDs (`AKIA…`/`ASIA…` 20 chars), Slack tokens (`xox[abposr]-`), Stripe secret
  keys (`sk_live_`/`rk_live_`), and PEM private-key blocks
  (`-----BEGIN … PRIVATE KEY-----`).

Dropped content is not logged, cached or kept in memory beyond the check.
Debug logging never includes clip content in any build.

### 2. Encryption at rest

- Storage dir: `~/Library/Application Support/Clipbot/`, mode 0700, files 0600,
  excluded from Time Machine (`isExcludedFromBackup`).
- Keys are **bound to this Mac's Secure Enclave**. The login Keychain item
  (service `io.linus.clipbot`, non-synchronizable, default app-only ACL) holds
  only a Secure Enclave P-256 key blob + a peer public key; the AES key is
  HKDF(ECDH(SE key, peer)). The blob is useless on any other Mac, so the key
  can't follow a Keychain migration or backup. (Found during build: the legacy
  login Keychain ignores `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so
  storing a raw key there would *not* have been device-only.) Macs without a
  Secure Enclave fall back to a raw key in the Keychain.
- Everything is sealed with **AES-256-GCM (CryptoKit)**:
  - one file per clip holding all its representations,
  - an encrypted index (order, timestamps, display previews, dedupe tags),
  - an encrypted snippets file.
- Writes are atomic (write temp-in-same-dir → rename); temp files contain only
  ciphertext.
- Dedupe tags are HMAC-SHA256 (key derived from the master key via HKDF), never
  plain hashes of content.
- Clear History = delete the clip files and index **and rotate the clip key**
  (crypto-shredding), so any blocks APFS left behind are unreadable. Snippets
  use a separate derived/stored key and survive Clear History.
- Decrypted data lives in memory only while needed: the index (previews) is held
  decrypted while running; full clip payloads are decrypted on demand (paste,
  thumbnail rendering).

### 3. No network

- No networking code, no third-party dependencies, no Sparkle, no analytics,
  no crash reporter.
- App Sandbox **enabled without** the `network.client`/`network.server`
  entitlements, so the OS enforces no-network — *if* synthesising ⌘V via
  Accessibility works from a sandboxed app on macOS 27 (builder verifies early).
  If it doesn't, ship Hardened Runtime unsandboxed, and add a test/CI check that
  the binary links no networking frameworks/symbols (`URLSession`, `Network`,
  `CFNetwork` sockets). Either way, report which path was taken.

### 4. Hardening (added at Linus's request: "absolutely locked down")

- **Spike result:** a sandboxed build *can* synthesise ⌘V (verified 2026-11-07),
  so the App Sandbox with no network entitlement ships. The OS blocks networking.
- **Universal Clipboard:** every pasteboard write Clipbot makes uses
  `prepareForNewContents(with: .currentHostOnly)`, so pasted history/snippets
  never sync to Linus's other Apple devices via Handoff.
- **Secure input:** if `IsSecureEventInputEnabled()` is true when a change is
  seen (a password field has focus somewhere), the change is dropped.
- **Hardened Runtime with zero exceptions** (no JIT, no unsigned memory, no
  DYLD env vars, library validation on, no `get-task-allow` in Release).
- **No entry points:** no URL scheme, no AppleScript dictionary, no Services, no
  XPC, no document types, no plugins/bundles loaded. Only entitlement is
  `app-sandbox` (+ `files.user-selected.read-write` for snippet import/export
  panels).
- **Keychain items** are created by the app, so their default ACL trusts only
  Clipbot's code signature; other apps get a user prompt.
- **Memory:** decrypted payloads are scoped to the paste/thumbnail call and not
  cached; no clip content in logs, `print`, `os_log`, crash breadcrumbs or
  exceptions.
- **Pasteboard reads** inspect `types` (metadata) before any data is read; data
  is read only after the filter passes.
- **CI-style checks** (`scripts/check-security.sh`): the binary links no
  networking frameworks, entitlements are exactly the allowed set, Hardened
  Runtime flag set, and the canary no-plaintext test passes.
- Out of Clipbot's control (documented in README): turn on FileVault, and
  optionally disable Handoff to stop *other* apps' copies syncing.

## Constraints

- Linus runs macOS 27 (Xcode 27, Swift 6.4). Deployment target macOS 15 or
  later is fine — this is a personal app. (Builder's call; newer is OK.)
- Recent macOS versions gate programmatic pasteboard reads behind a privacy
  permission ("Paste from Other Apps"/pasteboard access). Clipbot must detect
  when it lacks access, and tell Linus how to grant it, rather than silently
  recording nothing.
- Clipboard change detection: poll `NSPasteboard.general.changeCount` (there is
  no notification API); ~0.5 s interval, cheap.
- Signing: use the stable Apple Development certificate of the **personal team 8L83KP4DT8**
  (selected by team in `project.yml`), so Accessibility/Keychain grants survive rebuilds (ad-hoc signing
  would reset them every build). Built and installed locally to
  `/Applications/Clipbot.app`.
- Global hotkeys via Carbon `RegisterEventHotKey` (no dependency).
- Project generated with **xcodegen** (installed) from a checked-in
  `project.yml`; `.xcodeproj` not committed.
- Swift 6, AppKit for the menu/hotkeys/paste, SwiftUI for Settings and the
  snippet editor windows.

## Migration & switch-over

1. Build and install Clipbot; grant Accessibility + pasteboard access.
2. Linus exports snippets from Clipy (Clipy → Edit Snippets → Export) and
   imports them via Edit Snippets → Import from Clipy XML.
3. Quit Clipy, remove it from login items, then (with Linus's explicit OK)
   delete `Clipy.app` and its plaintext data folders
   (`~/Library/Application Support/Clipy`, `…/com.clipy-app.Clipy`).

## Testing

Unit tests (XCTest/Swift Testing) for the parts that can fail silently:

- secret filter: marker types, ignored apps, each key pattern, and non-secret
  look-alikes that must **not** be dropped;
- store: encrypt/decrypt round-trip, tamper detection, eviction at 100, dedupe
  move-to-top, Clear History key rotation makes old files undecryptable, no
  plaintext on disk (scan storage dir for a known test string);
- Clipy XML import.

Manual checks: the three hotkeys, menu shape, paste into a real app, copy from
1Password not recorded, own-paste not re-recorded, launch at login.

## Decisions after builder check

- **Other Clipy prefs** (Claude's call): Linus's plist only stores non-defaults;
  everything else is Clipy's default — 0 items inline, 10 per folder, reorder
  after paste on, paste after select on. The menu above matches those. No
  plain-text-paste modifier.
- **Size cap** (Claude's call): a clip whose stored representations exceed
  20 MB total is skipped entirely. Image thumbnails (small PNG) are generated
  at capture and stored encrypted in the index, so opening the menu never
  decrypts full payloads.
- **Snippet paste** (Claude's call): pasted as plain text, stays on the
  clipboard, not added to history.
- **Snippet durability** (Linus agreed): snippets stay device-only encrypted.
  Edit Snippets has **Export Snippets…** (Clipy-compatible XML, plaintext,
  snippets only — never clips) as the manual backup. If the Keychain key is
  missing/unreadable at launch: show a warning, move the existing encrypted
  files into a dated `Unreadable-<date>/` subfolder (never delete), start fresh.

## Left to the builder

Code structure, preview/thumbnail sizes, exact truncation length, file naming,
poll interval tuning, shortcut-recorder UI, app icon (simple, generic).

## Popup redesign (2026-11-08)

The Clipy-style `NSMenu` is replaced by Maccy's popup, at Justin's request ("Maccy's UI is way
better with the search bar"): a non-activating floating panel at the cursor with a search field,
one flat list (history, then snippets under a "Snippets" label), ⌘1…⌘0 on the first ten rows and
a footer with Clear History, Edit Snippets, Settings and Quit. Maccy's views and panel are ported
onto Clipbot's own stores rather than adding its dependencies (Defaults, KeyboardShortcuts, Sauce,
Fuse, SwiftData); the MIT notice is in `docs/licenses/Maccy.txt`. Left out: Maccy's preview
slideout, pins, paste stack and fuzzy/regex search.

- **Search** matches every word, in any order, ignoring case, accents and width. To match more than
  the 60-character preview without decrypting payloads when the popup opens, each new clip's text
  (capped at 2,000 characters) is stored as `searchText` in the encrypted index. Clips recorded
  before this have none and are searched by preview.
- **⌥⌫** deletes one clip (`HistoryStore.delete`). Snippets are only changed in the editor.
- Keys are matched by physical key code, so ⌘1…⌘0 work on every layout; keys pass through to the
  search field while an input method is composing.

