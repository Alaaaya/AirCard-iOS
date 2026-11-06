# Container multitask feasibility audit

Audited Mirsa production 7c50e6e and LiveContainer 9108ae624ea001f7d7696d48407f890b48fa2653 on 2026-11-06. Branch kat/container-multitask. No runtime implementation, no UI pretending to launch apps, no production changes.

## Concrete integration blockers

Mirsa has no guest-process extension target. project.yml only embeds MirsaLiveActivity, a widget extension, which cannot act as a guest application process. AppsStore.confirmLaunch writes process-global defaults then relaunches the whole host; GuestLoader takes over UIApplicationMain, mainBundle and HOME. It cannot be invoked again in the host to run an additional app safely.

A real implementation needs an extension bootstrap plus remote UIKit scene hosting. LiveContainer's LiveProcess/main.m interposes NSExtensionMain and UIApplicationMain, hooks dyld, then invokes LiveContainerMain. It is not a standalone extension to copy into Mirsa. MultitaskSupport/AppSceneViewController.m relies on private NSExtension request/PID APIs, RunningBoard and FrontBoard scenes; its Swift window views alone cannot display a guest.

Mirsa guest data/bundles are in the host's Application Support/AirCardApps. A separately sandboxed extension cannot simply consume those absolute paths. LiveContainer explicitly transfers scoped bookmarks, and supports shared app storage. Mirsa needs an audited minimal-access bookmark or app-group data handoff with cleanup, lifetime management and migration. Do not grant the entire host directory, where signing and account state may reside.

Mirsa is MIT licensed; LiveContainer is AGPL-3.0. No upstream code was copied. An attributed port cannot simply be declared MIT. Owner must choose a license-compliant combined distribution/source plan (keeping existing notices), obtain separate permission, or commission an independent implementation of the private process/scene bridge. This audit does not change the repository license.

## Signing / provisioning acceptance gate

Host and guest-process extension must be signed/provisioned under the same team, with valid parent-prefixed extension identifiers, matched entitlements and accessible guest code. A free developer account's App ID allowance must be checked on the real account before registering another extension, alongside existing host/widget registrations. Do not hardcode an available count or claim that unlimited processes consume no IDs. Multiple guest instances should reuse one extension target via multi-instance XPC configuration, not register one App ID per guest.

Keeping app extensions during installation is necessary but not sufficient. Missing extension must produce Arabic guidance to reinstall Mirsa while retaining extensions, not silently launch a fake window. The widget's presence is not a capability check for the guest-process extension.

## Recommended bounded next implementation

First establish one extension guest launch, security-scoped bundle/data access and embedded remote scene on a signed physical device, without changing cert/home UI. Verify distinct PIDs and successful independent termination, no host account/vault access, no shared mutable defaults, correct signature acceptance under actual free-account provisioning, and teardown after crashes.

Only after that gate, implement multiple sessions keyed by container ID (duplicate launch focuses existing session), resizable LTR glass windows, minimize/switch/close, per-app global/always/never routing and a global default. Active normal-launch conflicts need explicit handling before host relaunch. Do not expose enabled settings until the process bridge is functional.

## Validation status

Read-only code audit and documentation only. No compile/CI claim, no device test, no IPA, no merge or release. A baseline-only CI build would not validate any multitask behavior. Existing unsigned-ipa.yml dispatch avoids publish (publish steps require push), but has not been dispatched because there is no implementation to compile.

Sources: https://livecontainer.github.io/docs/guides/multitask and https://github.com/LiveContainer/LiveContainer at the pinned revision above.
