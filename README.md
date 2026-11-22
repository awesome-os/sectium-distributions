# Sectium Distributions (`awesome-os/sectium-distributions`)

Sovereign, zero-gatekeeper distribution tooling, SHA-256 verified release manifests, multi-OS static release profiles, and OEM self-signing guidance for **Sectium** and **Awesome-OS**.

## Sovereign One-Line Installers

Install verified `B8G_ABI_MAGIC_V3` (`0x33564742`) binaries directly from `https://awesome-os.com` with automatic SHA-256 verification against `release-manifest.json`:

**Windows (PowerShell):**
```powershell
irm https://awesome-os.com/install.ps1 | iex
```

**Linux / macOS (POSIX `sh`):**
```sh
curl -fsSL https://awesome-os.com/install.sh | sh
```

## Repository Contents

| Path | Description |
| :--- | :--- |
| `site/awesome-os.com/install.ps1` | Zero-gatekeeper Windows PowerShell web installer (`rolling` / `stable` channels, SHA-256 verification). |
| `site/awesome-os.com/install.sh` | Zero-gatekeeper POSIX `sh` web installer for Linux and macOS. |
| `site/awesome-os.com/release-manifest.json` | Canonical SHA-256 release manifest (`schemaVersion: 1`, `abiMagic: 0x33564742`, `abiVersion: 3`) covering `sectium-es`, `sectium-jvm`, and `sectium-cloud-control-plane`. |
| `sections/sectium-cloud-control-plane/web-installer.test.mts` | Hermetic verification suite for the web installers and release manifest integrity. |
| `intersections/sectium-browser/installer/release-profile.mts` | Multi-OS static release profile definitions (Windows, Linux, macOS, WASI). |
| `intersections/sectium-browser/installer/release-profile.test.mts` | Unit tests for static release profile generation and invariants. |
| `docs/architecture/DEVOPS-BUILD-DISTRIBUTION-AND-SIGNING-GUIDE.md` | Full **`holo-compiler`** Tier-A / Tier-B build, sovereign distribution, `RollingReleaseManifest` rollback, and OEM self-signing / OS vendor code-signing truth table. |

## Verification

```powershell
node --test intersections/sectium-browser/installer/release-profile.test.mts
node --test sections/sectium-cloud-control-plane/web-installer.test.mts
```

## License

BSD-3-Clause — see [`LICENSE`](LICENSE).
