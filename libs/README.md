# Native runtime deps

| File | Notes |
|------|--------|
| `clawlink-core.exe` | Elevated tunnel host (no console; `-H windowsgui`) |
| `wintun.dll` | amd64 build from https://www.wintun.net/ |
| `libfakeip.dll` | DNS / Fake-IP **DLL** from itunnel (Dart FFI) |

These are copied next to `clawlink.exe` under `libs/` at build/install time.

## libfakeip (DLL)

Source crate: **`E:\github\itunnel\crates\libfakeip`** (sibling repo; not vendored here).

```powershell
cd E:\github\itunnel\crates\libfakeip
cargo build --release
# → target\release\libfakeip.dll

# copy into clawlink
cd E:\github\clawlink
.\scripts\sync-libfakeip.ps1 -CopyOnly
# or build+copy in one step:
.\scripts\sync-libfakeip.ps1
```

Override: `$env:CLAWLINK_LIBFAKEIP_ROOT = 'E:\github\itunnel\crates\libfakeip'`
