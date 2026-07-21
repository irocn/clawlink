# ClawLink
Note!!! Winodws need version is win10+ and later.

Windows tray client for ClawLink / itunnel. The Flutter UI (`clawlink.exe`) talks to an elevated tunnel host (`clawlink-core.exe`) over a named pipe.

| Binary | Role | Privilege |
|--------|------|-----------|
| `clawlink.exe` | Flutter tray UI + local proxy | Administrator (UAC on launch) |
| `libs/clawlink-core.exe` | Tunnel host | Administrator |
| `libs/wintun.dll` | Wintun TUN driver helper | loaded by core |
| `libs/libfakeip.dll` | DNS / Fake-IP (Rust FFI) | loaded by GUI via Dart FFI |

Control pipe: `\\.\pipe\clawlink\control`

## Runtime

<table>
  <tr>
    <td align="center" width="50%">
      <img src="assets/start.PNG" alt="On startup" width="100%" /><br/>
      <sub>1. On startup</sub>
    </td>
    <td align="center" width="50%">
      <img src="assets/clawlink.PNG" alt="When connected" width="100%" /><br/>
      <sub>2. When connected</sub>
    </td>
  </tr>
</table>

## Layout

```
libs/
  clawlink-core.exe   # required; ship with the app
  wintun.dll          # amd64 from https://www.wintun.net/
  libfakeip.dll       # from sibling itunnel/crates/libfakeip
lib/                  # Dart sources (Flutter)
  fakeip/             # Dart FFI for libfakeip
assets/
windows/
  lib/                # CMake/sync output for libfakeip.dll
scripts/
  sync-libfakeip.ps1  # build + copy libfakeip without full Flutter build
```

Native runtime deps live in **`libs/`** (not Flutter’s Dart `lib/`).

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install/windows) (Windows desktop enabled)
- Visual Studio with “Desktop development with C++”
- Sibling **itunnel** at `../itunnel` (libfakeip crate: `itunnel/crates/libfakeip`)
- [Rust / cargo](https://rustup.rs/) only when rebuilding `libfakeip.dll`

## libfakeip DLL

ClawLink loads **`libfakeip.dll`** via Dart FFI (does not compile the Rust crate into this repo).

```powershell
cd E:\github\itunnel\crates\libfakeip
cargo build --release
# Windows → target\release\libfakeip.dll

cd E:\github\clawlink
.\scripts\sync-libfakeip.ps1 -CopyOnly
```

## Build

```powershell
flutter pub get
flutter build windows --release
```

The Windows install step copies `libs/clawlink-core.exe`, `libs/wintun.dll`, and `libs/libfakeip.dll` next to the built exe:

`build\windows\x64\runner\Release\libs\`

Or use the helper script:

```powershell
.\build.ps1
```

Artifacts are also mirrored under `output\`.

## Run

1. Start `clawlink.exe` (approve the UAC prompt — GUI needs Administrator for local proxy).
2. Paste an `itunnel://` invite and click **Connect**.
3. Approve the UAC prompt so `clawlink-core.exe` can start elevated (if it is not already covered by the same session).

## Updating core / wintun / libfakeip

Replace files under `libs/` then rebuild (or copy into `Release\libs\` for a quick test).

`clawlink-core.exe` is produced from the ClawLink engine repo (`cmd/clawlink-core`, build with `-ldflags "-H windowsgui"`).

`libfakeip.dll` comes from **`E:\github\itunnel\crates\libfakeip`** (`cargo build --release` → `target/release/libfakeip.dll`). Sync into this repo with `.\scripts\sync-libfakeip.ps1`.
