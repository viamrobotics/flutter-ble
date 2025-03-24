import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A Blueteooth Low Energy Central manager that allows you to scan and connect to devices.
class BleCentral {
  BleCentral._create();

  /// Creates and returns a singleton instance of a [BleCentral].
  static Future<BleCentral> create() async {
    final central = BleCentral._create();
    await central.reset();
    return central;
  }

  /// Resets the state of the manager.
  ///
  /// This is generally good and safe to call on any initial loading or reset of an app.
  Future<void> reset() => _BlePlatform.instance.centralManagerReset();

  /// Streams the power state of the manager over time.
  ///
  /// You must use this to verify [AdapterState.poweredOn] before calling scan or connect.
  Stream<AdapterState> getState() => _BlePlatform.instance.centralManagerGetState();

  /// Scans for peripherals that contain the optional list of given service ids.
  Stream<DiscoveredBlePeripheral> scanForPeripherals(List<String>? serviceIds) =>
      _BlePlatform.instance.centralManagerScanForPeripherals(serviceIds);

  /// Connects to the given peripheral discovered through scan or some other means.
  Future<ConnectedBlePeripheral> connectToPeripheral(String deviceId) => _BlePlatform.instance.centralManagerConnectToDevice(deviceId);
}

/// A Blueteooth Low Energy Peripheral manager that allows you to advertise and publish L2CAP channels.
class BlePeripheral {
  BlePeripheral._create();

  /// Creates and returns a singleton instance of a [BlePeripheral].
  static Future<BlePeripheral> create() async {
    final peripheral = BlePeripheral._create();
    await peripheral.reset();
    return peripheral;
  }

  /// Resets the state of the manager.
  ///
  /// This is generally good and safe to call on any initial loading or reset of an app.
  Future<void> reset() => _BlePlatform.instance.peripheralManagerReset();

  /// Streams the power state of the manager over time.
  ///
  /// You must use this to verify [AdapterState.poweredOn] before calling advertise or publish.
  Stream<AdapterState> getState() => _BlePlatform.instance.peripheralManagerGetState();

  /// Adds a service with string, read-only characteristics.
  ///
  /// Calling this method again with the same service uuid will replace the service.
  Future<void> addReadOnlyService(String uuid, Map<String, String> characteristicValues) =>
      _BlePlatform.instance.peripheralManagerAddReadOnlyService(uuid, characteristicValues);

  /// Starts advertising with the given local name along with any added services from [addReadOnlyService].
  Future<void> startAdvertising([String name = '']) => _BlePlatform.instance.peripheralManagerStartAdvertising(name);

  /// Publishes an L2CAP channel and returns the corresponding PSM and stream to await new channels.
  ///
  /// Note: although this returns a stream of channels, iOS centrals are not capable of connecting
  /// multiple times to the same PSM, so you may need to publish multiple PSMs for iOS
  /// devices unless you multiplex over a single channel.
  Future<(int, Stream<L2CapChannel>)> publishL2capChannel() => _BlePlatform.instance.peripheralManagerPublishChannel();

  /// Unpublishes the given PSM.
  Future<void> unpublishL2capChannel(int psm) => _BlePlatform.instance.peripheralManagerUnpublishChannel(psm);
}

/// A discovered peripheral returned from [BleCentral.scanForPeripherals]
class DiscoveredBlePeripheral {
  /// The id of the peripheral that can be used for connect.
  final String id;

  /// The name of the peripheral for additional verification.
  final String? name;

  DiscoveredBlePeripheral._private(this.id, this.name);
}

/// A connected peripheral returned from [BleCentral.connectToPeripheral]
class ConnectedBlePeripheral {
  /// The id of the peripheral.
  final String id;

  /// The services that the peripheral advertises.
  final List<BleService> services;

  ConnectedBlePeripheral._private(this.id, this.services);

  /// Disconnects from the peripheral.
  ///
  /// The instance is no longer usable after calling this method.
  Future<void> disconnect() => _BlePlatform.instance.centralManagerDisconnectFromDevice(id);

  /// Connects to the given PSM to establish L2CAP COC.
  Future<L2CapChannel> connectToL2CapChannel(int psm) => _BlePlatform.instance.centralManagerConnectToChannel(id, psm);

  /// Determines if multiple connectToL2CapChannel calls should work.
  bool get isMultipleChannelForPSMSupported {
    return !Platform.isIOS;
  }
}

/// An advertised BLE service.
class BleService {
  /// The id of the service.
  final String id;

  /// The device id that this service belongs to.
  final String deviceId;

  /// The characteristics of this service.
  final List<BleCharacteristic> characteristics;

  BleService._private(this.id, this.deviceId, this.characteristics);
}

/// An advertised BLE characteristic.
class BleCharacteristic {
  /// The id of the characteristic.
  final String id;

  /// The id of the service.
  final String serviceId;

  /// The device id that this service belongs to.
  final String deviceId;

  BleCharacteristic._private(this.id, this.serviceId, this.deviceId);

  /// Reads the latest value of the characteristic.
  Future<Uint8List?> read() => _BlePlatform.instance.centralManagerReadCharacteristic(deviceId, serviceId, id);

  /// Writes the given data to the characteristic.
  Future<void> write(Uint8List data) => _BlePlatform.instance.centralManagerWriteCharacteristic(deviceId, serviceId, id, data);
}

/// The various states of the BLE adapter.
enum AdapterState {
  /// The adapter is powered off.
  poweredOff,

  /// The adapter is powered on.
  poweredOn,

  /// The adapter is resetting.
  resetting,

  /// The adapter is not allowed to be used.
  unauthorized,

  /// The adapter is unsupported.
  unsupported,

  /// The state is unknown.
  unknown;

  static AdapterState _fromPlatform(int value) {
    switch (value) {
      case 0:
        return AdapterState.unknown;
      case 1:
        return AdapterState.resetting;
      case 2:
        return AdapterState.unsupported;
      case 3:
        return AdapterState.unauthorized;
      case 4:
        return AdapterState.poweredOff;
      case 5:
        return AdapterState.poweredOn;
      default:
        return AdapterState.unknown;
    }
  }
}

/// Error indicating that the relevant L2Cap COC is disconnected.
class L2CapDisconnectedError extends Error {
  final String _message;

  /// Creates a new L2CapDisconnectedError.
  L2CapDisconnectedError(this._message);

  @override
  String toString() {
    return 'L2CapDisconnectedError: $_message';
  }
}

/// A simple, raw read and write wrapper around an L2CAP COC.
abstract class L2CapChannel {
  /// Writes to the channel and returns how much was written.
  Future<int> write(Uint8List data);

  /// Reads up to maxRead bytes for the channel and returns how much was written.
  Future<Uint8List?> read(int maxRead);

  /// Closes the channel.
  ///
  /// Note: Further reads and write fail.
  Future<void> close();
}

class _BlePlatform extends PlatformInterface {
  _BlePlatform() : super(token: _token);

  static final Object _token = Object();

  static final _BlePlatform _instance = _BlePlatform();

  static _BlePlatform get instance => _instance;

  final methodChannel = const MethodChannel('ble');

  static const String centralManagerScanForPeripheralsNotificationName = 'centralManagerScanForPeripherals';
  static const String centralManagerGetStateNotificationName = 'centralManagerGetState';
  static const String peripheralManagerGetStateNotificationName = 'peripheralManagerGetState';
  static const String uuidParamName = 'uuid';
  static const String characteristicsParamName = 'characteristics';
  static const String psmParamName = 'psm';
  static const String cidParamName = 'cid';
  static const String nameParamName = 'name';
  static const String dataParamName = 'data';
  static const String maxReadParamName = 'max_read';
  static const String deviceIdParamName = 'device_id';
  static const String serviceIdParamName = 'service_id';
  static const String characteristicIdParamName = 'characteristic_id';

  // Peripheral methods
  Future<void> peripheralManagerReset() async {
    return methodChannel.invokeMethod<void>('peripheralManagerReset');
  }

  Stream<AdapterState> peripheralManagerGetState() {
    final stream = const EventChannel(peripheralManagerGetStateNotificationName).receiveBroadcastStream().cast<int>();
    return stream.asyncMap((event) {
      return AdapterState._fromPlatform(event);
    });
  }

  Future<void> peripheralManagerAddReadOnlyService(String uuid, Map<String, String> characteristicValues) async {
    return methodChannel
        .invokeMethod<void>('peripheralManagerAddReadOnlyService', {uuidParamName: uuid, characteristicsParamName: characteristicValues});
  }

  Future<void> peripheralManagerStartAdvertising(String name) async {
    return methodChannel.invokeMethod<void>('peripheralManagerStartAdvertising', {nameParamName: name});
  }

  Future<(int, Stream<L2CapChannel>)> peripheralManagerPublishChannel() async {
    final psm = await methodChannel.invokeMethod<int>('peripheralManagerPublishChannel');
    if (psm == null) {
      throw Exception('failed to publish channel');
    }

    final stream = const EventChannel('peripheralManagerChannelOpened')
        .receiveBroadcastStream({psmParamName: psm})
        .cast<int>()
        .map((cid) => _L2CapChannelToCentral(psm, cid));
    return (psm, stream);
  }

  Future<void> peripheralManagerUnpublishChannel(int psm) async {
    return methodChannel.invokeMethod<void>('peripheralManagerUnpublishChannel', {psmParamName: psm});
  }

  // Note: This assumes the platform's underlying write method is blocking/serial.
  Future<int> peripheralManagerWriteToChannel(int psm, int cid, Uint8List data) async {
    final response = await methodChannel
        .invokeMethod<int>('peripheralManagerWriteToChannel', {psmParamName: psm, cidParamName: cid, dataParamName: data});
    return response ?? -1;
  }

  // Note: This assumes the platform's underlying read method is blocking/serial.
  Future<Uint8List?> peripheralManagerReadFromChannel(int psm, int cid, int maxRead) async {
    return methodChannel
        .invokeMethod<Uint8List>('peripheralManagerReadFromChannel', {psmParamName: psm, cidParamName: cid, maxReadParamName: maxRead});
  }

  Future<void> peripheralManagerCloseChannel(int psm, int cid) async {
    return methodChannel.invokeMethod<void>('peripheralManagerCloseChannel', {
      psmParamName: psm,
      cidParamName: cid,
    });
  }

  // Central methods
  Future<void> centralManagerReset() async {
    return methodChannel.invokeMethod<void>('centralManagerReset');
  }

  Stream<AdapterState> centralManagerGetState() {
    final stream = const EventChannel(centralManagerGetStateNotificationName).receiveBroadcastStream().cast<int>();
    return stream.asyncMap((event) {
      return AdapterState._fromPlatform(event);
    });
  }

  Stream<DiscoveredBlePeripheral> centralManagerScanForPeripherals(List<String>? serviceIds) {
    final stream = const EventChannel(centralManagerScanForPeripheralsNotificationName)
        .receiveBroadcastStream({'service_ids': serviceIds}).cast<Map<Object?, Object?>>();
    return cancelWrapper(stream.asyncMap((event) {
      return DiscoveredBlePeripheral._private(event['id']! as String, event['name'] as String?);
    }), () => centralManagerStopScanningForPeripherals());
  }

  Future<void> centralManagerStopScanningForPeripherals() async {
    return methodChannel.invokeMethod<void>('centralManagerStopScanningForPeripherals');
  }

  Future<ConnectedBlePeripheral> centralManagerConnectToDevice(String deviceId) async {
    final success = await methodChannel.invokeMethod<List<Object?>>('centralManagerConnectToDevice', {deviceIdParamName: deviceId});
    if (success == null) {
      throw Exception('failed to connect');
    }

    return ConnectedBlePeripheral._private(
        deviceId,
        success.map((svc) {
          final svcMap = svc! as Map<Object?, Object?>;
          final svcId = svcMap['id']! as String;
          final charsRaw = svcMap[characteristicsParamName]! as List<Object?>;
          final characteristics = charsRaw.map((charRaw) {
            final charMap = charRaw! as Map<Object?, Object?>;
            return BleCharacteristic._private(charMap['id']! as String, svcId, deviceId);
          }).toList();
          return BleService._private(svcMap['id']! as String, deviceId, characteristics);
        }).toList());
  }

  Future<void> centralManagerDisconnectFromDevice(String deviceId) async {
    await methodChannel.invokeMethod<void>('centralManagerDisconnectFromDevice', {deviceIdParamName: deviceId});
  }

  Future<Uint8List?> centralManagerReadCharacteristic(String deviceId, String serviceId, String characteristicId) async {
    return methodChannel.invokeMethod<Uint8List>('centralManagerReadCharacteristic',
        {deviceIdParamName: deviceId, serviceIdParamName: serviceId, characteristicIdParamName: characteristicId});
  }

  Future<void> centralManagerWriteCharacteristic(String deviceId, String serviceId, String characteristicId, Uint8List data) async {
    return methodChannel.invokeMethod<void>('centralManagerWriteCharacteristic', {
      deviceIdParamName: deviceId,
      serviceIdParamName: serviceId,
      characteristicIdParamName: characteristicId,
      dataParamName: data,
    });
  }

  Future<L2CapChannel> centralManagerConnectToChannel(String deviceId, int psm) async {
    final cid = await methodChannel.invokeMethod<int>('centralManagerConnectToChannel', {deviceIdParamName: deviceId, psmParamName: psm});
    if (cid == null) {
      throw Exception('failed to connect');
    }
    return _L2CapChannelToPeripheral(deviceId, psm, cid);
  }

  // Note: This assumes the platform's underlying write method is blocking/serial.
  Future<int> centralManagerWriteToChannel(String deviceId, int psm, int cid, Uint8List data) async {
    final response = await methodChannel.invokeMethod<int>(
        'centralManagerWriteToChannel', {deviceIdParamName: deviceId, psmParamName: psm, cidParamName: cid, dataParamName: data});
    return response ?? -1;
  }

  // Note: This assumes the platform's underlying read method is blocking/serial.
  Future<Uint8List?> centralManagerReadFromChannel(String deviceId, int psm, int cid, int maxRead) async {
    return methodChannel.invokeMethod<Uint8List>(
        'centralManagerReadFromChannel', {deviceIdParamName: deviceId, psmParamName: psm, cidParamName: cid, maxReadParamName: maxRead});
  }

  Future<void> centralManagerCloseChannel(String deviceId, int psm, int cid) async {
    return methodChannel
        .invokeMethod<void>('centralManagerCloseChannel', {deviceIdParamName: deviceId, psmParamName: psm, cidParamName: cid});
  }

  static Stream<T> cancelWrapper<T>(Stream<T> source, void Function() onCancel) async* {
    bool isCancelled = true;
    try {
      await for (var event in source) {
        yield event;
      }
      isCancelled = false;
    } finally {
      if (isCancelled) {
        onCancel();
      }
    }
  }
}

/// This is a channel going from a peripheral to a central. This could be just one class combined
/// with [_L2CapChannelToPeripheral] with a switch on deviceId but it's small enough to duplicate
/// for now.
class _L2CapChannelToCentral extends L2CapChannel {
  final int psm;
  final int cid;

  _L2CapChannelToCentral(this.psm, this.cid);

  @override
  Future<int> write(Uint8List data) => _BlePlatform.instance.peripheralManagerWriteToChannel(psm, cid, data);

  @override
  Future<Uint8List?> read(int maxRead) => _BlePlatform.instance.peripheralManagerReadFromChannel(psm, cid, maxRead);

  @override
  Future<void> close() => _BlePlatform.instance.peripheralManagerCloseChannel(psm, cid);
}

class _L2CapChannelToPeripheral extends L2CapChannel {
  final String deviceId;
  final int psm;
  final int cid;

  _L2CapChannelToPeripheral(this.deviceId, this.psm, this.cid);

  @override
  Future<int> write(Uint8List data) => _BlePlatform.instance.centralManagerWriteToChannel(deviceId, psm, cid, data);

  @override
  Future<Uint8List?> read(int maxRead) => _BlePlatform.instance.centralManagerReadFromChannel(deviceId, psm, cid, maxRead);

  @override
  Future<void> close() => _BlePlatform.instance.centralManagerCloseChannel(deviceId, psm, cid);
}
