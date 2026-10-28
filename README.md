# big wallet by [lil.org](https://lil.org)
crypto wallet with a safari extension

ios / macos / visionos

connect like metamask in safari

download on the [app store](https://lil.org/get)

## development

Use Xcode 27 or newer with Swift 6.4. Native targets use Swift 6 language mode.
Minimum supported versions are iOS 26, macOS 15, and visionOS 2.

Builds and tests run in the dedicated headless macOS VM. From the repository root:

```sh
Scripts/test_vm.sh doctor
Scripts/test_vm.sh setup
Scripts/test_vm.sh run all
```

The default suite uses fixture dependencies and ad-hoc signing without Apple
signing credentials or the production RPC proof key. `--signing apple` adds builds
using the provisioned Apple identity, production entitlements, and proof resource.
Use `run extended` for the broader suite, or `run all --stage STAGE` for focused validation. Native builds,
tests, simulators, authentication, and helper cleanup must stay off the working
host; an unavailable VM has no local fallback.

- [VM setup, suites, lifecycle checks, and reports](Scripts/vm/README.md)
- [Runtime architecture, authority, and secret handling](Packages/WalletRuntime/README.md)
- [Safari protocol, provider behavior, and generation](Safari%20Shared/Protocol/README.md)
- [Maintenance, release checks, and troubleshooting](MAINTENANCE.md)
- [Alchemy JWT Worker operations](Workers/alchemy-jwt/README.md)
