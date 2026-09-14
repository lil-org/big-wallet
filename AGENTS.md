Avoid code comments except for TODOs or essential context.

Use Xcode's default DerivedData location for project builds. Do not pass a
temporary `-derivedDataPath`; macOS build products can leave stale Safari
extension processes running from that location.

Commits that exist only on off-main development branches have not been released.
Do not add or retain migrations, fallback readers, protocol adapters, or
compatibility tests solely for intermediate development versions. Update
producers, consumers, and tests together when changing unreleased formats.
Preserve compatibility with distributed main versions and external protocol
standards. Version numbers and historical development fixtures do not establish
that a format shipped.
