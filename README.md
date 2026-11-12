# ClassicAFP

Bring `afp://` network volumes back to modern macOS with a menubar app and an FSKit file-system extension. AFP protocol support comes from [Netatalk Client](https://github.com/Netatalk/netatalk-client).

## Features

- Mount AFP shares in Finder under `/Volumes`
- Menubar agent for favorites and connect / eject
- Passwords stored in the Keychain
- Bonjour discovery of AFP servers on the local network
- Reconnect after wake / network changes (optional per favorite)
- In-app diagnostics log

## Download

Get the latest macOS disk image from [Releases](https://github.com/marcowilka/classic548/releases/latest).

## Install

1. Open the DMG and drag **ClassicAFP** to Applications.
2. Launch ClassicAFP (menubar icon).
3. Enable the ClassicAFP File System Extension when prompted (System Settings → General → Login Items & Extensions → File System Extensions).
4. Add a share (host, volume, username, password) and Connect.

## Source

The repository contains the full source if you want to build it yourself.

## License

ClassicAFP application sources are MIT. Bundled Netatalk Client helpers (`Helpers/`) are GPL-2; see `Helpers/COPYING-netatalk-client`.
