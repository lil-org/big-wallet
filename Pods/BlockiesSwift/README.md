<a href="https://github.com/Boilertalk/VaporFacebookBot">
  <img src="https://storage.googleapis.com/boilertalk/logo.svg" width="100%" height="256">
</a>

<p align="center">
  <a href="https://travis-ci.org/Boilertalk/BlockiesSwift">
    <img src="http://img.shields.io/travis/Boilertalk/BlockiesSwift.svg?style=flat" alt="CI Status">
  </a>
  <a href="http://cocoapods.org/pods/BlockiesSwift">
    <img src="https://img.shields.io/cocoapods/v/BlockiesSwift.svg?style=flat" alt="Version">
  </a>
  <a href="http://cocoapods.org/pods/BlockiesSwift">
    <img src="https://img.shields.io/cocoapods/l/BlockiesSwift.svg?style=flat" alt="License">
  </a>
  <a href="http://cocoapods.org/pods/BlockiesSwift">
    <img src="https://img.shields.io/cocoapods/p/BlockiesSwift.svg?style=flat" alt="Platform">
  </a>
  <a href="https://github.com/Carthage/Carthage">
    <img src="https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat" alt="Carthage compatible">
  </a>
</p>

# :alembic: BlockiesSwift

<p align="center">
  <img src="https://github.com/Boilertalk/BlockiesSwift/raw/master/sample.png" alt="Sample Blockies">
</p>

This library is a Swift implementation of the [Ethereum fork of Blockies](https://github.com/ethereum/blockies) which is intended to be used in iOS, watchOS, tvOS and macOS apps.

Blockies generates unique images (identicons) for a given seed string. Those can be used to create images representing an Ethereum (or other Cryptocurrency) Wallet address or really anything else.

## Example

To run the example project, run `pod try BlockiesSwift`. Or clone the repo, and run `pod install` from the Example directory.

## Installation

### CocoaPods

BlockiesSwift is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your `Podfile`:

```ruby
pod 'BlockiesSwift'
```

### Carthage

BlockiesSwift is compatible with [Carthage](https://github.com/Carthage/Carthage), a decentralized dependency manager that builds your dependencies and provides you with binary frameworks. To install it, simply add the following line to your `Cartfile`:

```
github "Boilertalk/BlockiesSwift"
```

## Usage

Basic usage is very straight forward. You just create an instance of `Blockies` with your seed and call `createImage()` to get your image.

```Swift
import BlockiesSwift

let blockies = Blockies(seed: "0x869bb8979d38a8bc07b619f9d6a0756199e2c724")
let img = blockies.createImage()

yourImageView.image = img
```

This will generate an image with `size` set to 8 and `scale` set to 4. `size` is the width and height of the Blockies image in blocks, `scale` is the width and height of one block in pixels.

Per default, random colors are generated for the given seed. You can change that but keep in mind that the pattern will also change if you provide custom colors as there will be less calls to the internal `random()` function.

The following is a full example.

```Swift
import BlockiesSwift

let blockies = Blockies(
    seed: "0x869bb8979d38a8bc07b619f9d6a0756199e2c724",
    size: 5,
    scale: 10,
    color: UIColor.green,
    bgColor: UIColor.gray,
    spotColor: UIColor.orange
)
let img = blockies.createImage()

yourImageView.image = img
```

The following sizes work well for most cases.

* size: 8, scale: 3
* size: 5, scale: 10

Sizes above 10 generate more noisy structures. If you want to generate bigger images, you can go for a set of `size` and `scale` from the above and pass a `customScale` value to `createImage(_:)`.

```Swift
import BlockiesSwift

let blockies = Blockies(
    seed: "0x869bb8979d38a8bc07b619f9d6a0756199e2c724",
    size: 8,
    scale: 3
)
let img = blockies.createImage(customScale: 10)

yourImageView.image = img
```

The image in this example would be `8 * 3 = 24x24` pixels without a custom scale. With the `customScale` set to `10` it will be `8 * 3 * 10 = 240x240` pixels. The `customScale` lets you generate bigger images with the same structure quality as the smaller ones.

## Author

Koray Koska, koray@koska.at

## License

BlockiesSwift is available under the MIT license. See the LICENSE file for more info.
