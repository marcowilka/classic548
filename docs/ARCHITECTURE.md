# ClassicAFP Architecture

## Goal

Restore `afp://` network volumes on modern macOS after Apple removed the built-in AFP client. Volumes appear under `/Volumes` via **FSKit**; the menubar AppKit agent manages favorites, credentials, login launch, and mounts.

## Processes

1. **ClassicAFP.app** (LSUIElement, AppKit)
   - Status item + favorites UI
   - Starts bundled `Contents/Helpers/afpsld`
   - Exposes a loopback TCP→Unix proxy so the sandboxed appex can reach `afpsld`
   - Calls `FSClient.mountSingleVolume(resource:bundleID:options:)` with `FSGenericURLResource(afp://…)`
   - Stores passwords in Keychain; bookmarks in `UserDefaults`

2. **AFPFS.appex** (FSKit module, sandboxed)
   - Declares `FSSupportedSchemes = [afp]`
   - Implements `FSUnaryFileSystem` + `FSVolume` read/write ops
   - Talks to `afpsld` through **AFPBridge** / `libafpsl` via `AFPSL_TCP_PORT` (loopback)

3. **afpsld** (Netatalk Client, GPL-2)
   - Owns long-lived AFP/DSI sessions
   - Listens on a Unix socket under `/tmp` (host helper); appex does not connect there directly

## Mount flow

```
Menubar Connect
  -> ensure afpsld running + TCP proxy
  -> FSClient.mountSingleVolume(FSGenericURLResource(afp://…))
  -> fskitd loads AFPFS
  -> probe/loadResource/activate
  -> AFPClient.connect + attach (via TCP proxy → afpsld)
  -> Volume visible in Finder under /Volumes
```

## License boundary

- `Helpers/afpsld` + `libafpsl` / `libafpclient` are GPL-2 (Netatalk Client).
- Host app communicates with the daemon over IPC; the helper ships as a separate GPL artifact (`Helpers/COPYING-netatalk-client`).

## Enabling the extension

System Settings → General → Login Items & Extensions → File System Extensions → enable **ClassicAFP**.

## Diagnostics

- Menubar → **Diagnostics…**
- Rolling file: `~/Library/Logs/ClassicAFP/latest.log`

## Reconnect

On wake / network change the agent restarts `afpsld` if needed and remounts favorites marked **Connect at login**.
