# Apps tab (sideloader + Container) — third-party notices

| Component | License | Use |
|---|---|---|
| [isideload](https://github.com/nab138/isideload) (nab138) | MIT | Apple ID sign-in (GSA/SRP + 2FA), anisette, free development certificate, App IDs, provisioning profiles, app signing |
| [idevice](https://github.com/jkcoxson/idevice) (jkcoxson) | MIT | AFC + installation_proxy over the on-device loopback tunnel (already used by AirCard) |
| [apple-codesign-quick](https://github.com/Dadoum/apple-codesign-quick) (Dadoum) | **LGPL-2.1-or-later** | Mach-O / bundle code signing (dependency of isideload, also called directly by the Container signer) |

## LGPL note
`apple-codesign-quick` is statically linked into `libairlift_ffi.a`. LGPL-2.1
requires that users can relink the application with a modified version of the
library. AirCard satisfies this by publishing its complete source, `Cargo.lock`
and build scripts (`build-ios.sh`, `build-ipa.sh`, `.github/workflows/unsigned-ipa.yml`).
Anyone distributing an AirCard IPA must keep this notice and point to the source.

## Not used
- **LiveContainer** (AGPL-3.0): no code copied. `ios-app/Apps/GuestLoader.m` and
  `rust-core/src/container.rs` are independent implementations of the general
  "load an app executable as a library" technique.
- **SideStore / AltStore** (AGPL-3.0), **SideInstaller** (non-commercial, no
  binary redistribution), **ldid** (AGPL-3.0), **zsign** (MIT): no code used.

## Network services
Anisette data is fetched from isideload's default public anisette server
(configurable in Apps → Settings). The Apple ID password is only sent to Apple.
