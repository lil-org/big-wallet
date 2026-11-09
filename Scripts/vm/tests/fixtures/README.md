`xcode27_2_runtime_enumeration.json` is the unmodified flat JSON emitted by Xcode
27.2 (27B52) for the macOS Debug package test plan in VM run
`run-20261108T120326Z-d68700cd`, source commit
`c98215cb4546be693aa70465a1d9f95111560491`. Its 1,796 identifiers matched the
former source inventory exactly. Parser and ASan policy tests use this fixed
output. Orchestration tests use a small synthetic inventory.

`xcode27_2_app_enumeration.json` is the corresponding unmodified macOS Debug app
output from VM run `run-20261108T123935Z-4506ac66`. Its 485 identifiers contain all
415 methods protected by the former critical-app inventory.

`xcode27_2_ios_app_enumeration.json` was recovered from interrupted VM run
`run-20261108T124709Z-196af388`. Xcode emits 330 executable methods and one empty
`CustomNetworkPackagingTests` class marker. All 194 former critical-app methods
are present; empty class markers are not runnable tests or selector matches.

`xcode27_2_asan_plan.json` is the unmodified package ASan plan from passing VM run
`run-20261108T131021Z-608f3989`, which captured ordinary package/app discovery on
all six platform/configuration variants and both macOS Debug ASan families.
Every prior critical app test was present: 415 macOS, 194 iOS, and 194 visionOS
methods in both Debug and Release. Sanitizer runtime bindings come from the
captured plan, not the unrelated memory-tagging flag.

`xcode27_2_tsan_plan.json` is the unmodified package TSan plan from VM run
`run-20261108T143640Z-20ae1c92`; its 56 selected runtime tests passed. The separate
app preview failures in that run do not establish an app TSan pass.
