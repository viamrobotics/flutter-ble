# Bluetooth Low Energy Flutter Package

[![license](https://img.shields.io/badge/license-Apache_2.0-blue)](https://github.com/viamrobotics/flutter-ble/blob/main/LICENSE)

This package provides the following features:

- Central
	- Discover peripherals and their services and charactersitics
	- Read values from characteristics
	- Connect to peripherals
	- Establish L2CAP COC connections over discovered/known PSMs.
	- Multiplex L2CAP COCs into sockets.
- Peripheral
	- Advertise read-only, string based services and charactersitics
	- Publish L2CAP COC connections.
	- Multiplex L2CAP COCs into sockets.

## Getting started

Make sure your project meets the minimum requirements:

- Minimum iOS target: 13.0
- Minimum Android SDK: 29
- Kotlin version: 1.7.10

## iOS Permissions

### Update Info.plist

If you are building for Apple platforms, you may have to update your app's `Info.plist`. `NSBluetoothAlwaysUsageDescription` is needed to utilize bluetooth.

```plist
<key>NSBluetoothAlwaysUsageDescription</key>
<string></string>
```

## Android Permissions

See https://developer.android.com/develop/connectivity/bluetooth/bt-permissions for how to correctly declare and request permissions for Android devices you intend on supporting.

## Usage and example apps

View example apps in the [`/example`](https://github.com/viamrobotics/flutter-ble/blob/main/example/) directory to learn how to best use this package. There are two combined examples:
- [central](https://github.com/viamrobotics/flutter-ble/tree/main/example/central) and [peripheral](https://github.com/viamrobotics/flutter-ble/tree/main/example/peripheral)
  - Demonstrates a central and peripheral sending messages to each over L2CAP channels.
- [central_socks_client](https://github.com/viamrobotics/flutter-ble/tree/main/example/central_socks_client) and [peripheral_socks_server](https://github.com/viamrobotics/flutter-ble/tree/main/example/peripheral_socks_server)
  - Demonstrates a central and peripheral acting as a client and server for doing HTTP over SOCKS5.

## GitHub

You can view the code for Flutter BLE on [GitHub](https://github.com/viamrobotics/flutter-ble).

## Original Credit

This project took learnings from https://github.com/appsfactorygmbh/flutter-l2cap and as such references its MIT LICENSE at the bottom of our Apache 2.0 LICENSE.

## License

Copyright 2021-2024 Viam Inc.

Apache 2.0 - See [LICENSE](https://github.com/viamrobotics/flutter-ble/blob/main/LICENSE) file
