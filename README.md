# Port Watch

A native macOS menu bar app for finding and safely stopping local TCP listeners.

[![CI](https://github.com/solnce/portwatch/actions/workflows/ci.yml/badge.svg)](https://github.com/solnce/portwatch/actions/workflows/ci.yml)

[日本語](#日本語) · [Build](#build-from-source) · [Safety](#process-safety)

## Features

- Shows the number of TCP listening ports in the menu bar.
- Lists ports, process names, PIDs, bind addresses, users, and working directories.
- Filters by port, process, or path.
- Highlights processes still running from a deleted working directory.
- Refreshes automatically every five seconds.
- Builds as a Universal 2 app for Apple Silicon and Intel Macs.
- Sends `SIGTERM` only after an explicit confirmation.
- Revalidates the PID, owner, start time, and macOS audit token immediately before stopping.
- Does not use `sudo`, telemetry, external network access, or persistent process-history storage.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools with Swift 6

Port Watch currently supports source builds. The generated app is ad-hoc signed and is not notarized by Apple.

## Build from source

```bash
git clone https://github.com/solnce/portwatch.git
cd portwatch
./scripts/build-app.sh release
open "dist/Port Watch.app"
```

To keep it in your user Applications folder:

```bash
mkdir -p "$HOME/Applications"
ditto "dist/Port Watch.app" "$HOME/Applications/Port Watch.app"
open "$HOME/Applications/Port Watch.app"
```

The app runs only in the menu bar and does not show a Dock icon. Choose **終了** at the bottom of the panel to quit.

## Usage

1. Click the network icon and port count in the macOS menu bar.
2. Search or filter the listening-port list.
3. Click the red stop icon for a process.
4. Review the PID, user, ports, and working directory.
5. Click **停止** to send `SIGTERM`, or **キャンセル** to return.

## Process safety

Port Watch can stop only a process owned by the current user. Before sending `SIGTERM`, it performs a fresh scan and requires the displayed and current `PID + start time + UID + audit token` to match. This prevents a reused PID from targeting a different process. Root and setuid-style execution contexts are refused.

Port Watch does not force-kill processes, stop process groups, monitor UDP, or start processes.

The app intentionally does not use App Sandbox because it must inspect and signal local processes. It does not request administrator privileges.

## Development

```bash
swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

The test suite covers individual parsing and permission cases, repeated and concurrent refresh/stop operations, scan-order races, and a 5,000-listener load case.

## 日本語

Port Watchは、ローカルでTCPポートを待ち受けているプロセスをmacOSのメニューバーから確認・停止できるアプリです。

macOS 14以降とSwift 6対応のXcode Command Line Toolsが必要です。上記の手順でビルド後、メニューバーのネットワークアイコンから利用できます。停止対象は現在のユーザーが所有するプロセスに限定され、停止直前にPID・開始時刻・UID・監査トークンを再検証します。

## License

MIT License. See [LICENSE](LICENSE).
