# Code Style

We mostly rely on SwfitLint for code formation, however some conseptual decisions(naming related issues included) are outlined here.

## Conditionals using macros

We always use 
```swift5
#if canImport(UIKit) 
...
#elseif canImport(AppKit)
...
#endif 
``` 

Contrary to 
```swift5
#if os(iOS) || os(tvOS) || os(watchOS)
...
```

this allows to focus on needed functionality and ensures that the import target only what we are interested in.
