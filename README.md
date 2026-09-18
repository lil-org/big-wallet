# big wallet by [lil.org](https://lil.org)
crypto wallet with a safari extension

ios / macos / visionos

connect like metamask in safari

download on the [app store](https://lil.org/get)

## development

* run the xcode project
* recurring manual chores live in [MAINTENANCE.md](MAINTENANCE.md)

### iPhone debugger launch stalls in Xcode 27

On Xcode 27.0 (27A266a) with iOS 27.0 (24A437), device debugging can stall at "Configuring Observers for Extensions and XPC Services" with CoreDevice error 1001 for `com.apple.instruments.dtservicehub`. The `Wallet iOS` scheme disables "Debug XPC services used by app" while keeping the app's LLDB debugger enabled.

If launch then stalls at "Launching Big Wallet", Xcode's `IDEDyldMetricsCollector` can also block waiting for the Instruments connection. When the Xcode process sample confirms that wait, quit Xcode and apply this local workaround before reopening it:

```sh
defaults write com.apple.dt.Xcode IDEDyldMetricsEnabled -bool NO
```

This private Xcode preference disables dyld launch-metrics collection across projects; it does not change the app or its release build. Other Instruments-dependent diagnostics may still be unavailable while the device connection reports the capability error. After an Xcode/device-support update, quit Xcode and remove the override to retest the default behavior:

```sh
defaults delete com.apple.dt.Xcode IDEDyldMetricsEnabled
```
