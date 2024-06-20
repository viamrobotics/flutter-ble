// ignore_for_file: avoid_print, public_member_api_docs
import 'dart:async';

import 'package:ble/ble.dart';
import 'package:ble/ble_peripheral.dart';
import 'package:ble/ble_socket.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socks5_proxy/socks_server.dart';

List<String> lines = [];

void main() {
  runZoned(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      Permission.bluetoothConnect.request().then((status) => Permission.bluetoothAdvertise.request()).then((status) {
        BlePeripheral.create().then((ble) {
          final stateStream = ble.getState();
          late StreamSubscription<AdapterState> streamSub;
          streamSub = stateStream.listen((state) {
            if (state == AdapterState.poweredOn) {
              streamSub.cancel();
              publishAndListen(ble);
            }
          });
        });
      });

      runApp(const MyApp());
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) async {
        if (lines.length > 30) {
          lines.removeAt(0);
        }
        lines.add('${DateTime.now()}: $line');
        parent.print(zone, line);
      },
    ),
  );
}

var generation = 0;

Future<void> publishAndListen(BlePeripheral ble) async {
  // Note: These must be unique among applications
  const testSvcUUID = '00000000-0000-1234-0001-000000000000';
  const testPSMCharUUID = '00000000-0000-1234-0001-000000000001';
  const deviceName = 'TestBT1';

  await ble.reset();

  final (psm, chanStream) = await ble.publishL2capChannel();
  print('will publish psm: $psm');
  await ble.addReadOnlyService(testSvcUUID, {testPSMCharUUID: '$psm'});
  await ble.startAdvertising(deviceName);

  var chanCount = 0;
  print('waiting for connections');

  chanStream.listen((chan) async {
    final thisCount = chanCount++;
    print('serve channel $thisCount as a SOCKS5 server');
    final socksServerProxy = SocksServer();
    socksServerProxy.connections.listen((connection) async {
      print(
          'forwarding ${connection.address.address}:${connection.port} -> ${connection.desiredAddress.address}:${connection.desiredPort}');
      await connection.forward(allowIPv6: true);
    }).onError(print);

    // Note: Depending on the application you may want to know when the channel closes which
    // would need to be added to L2CapChannel.
    unawaited(socksServerProxy.addServerSocket(L2CapChannelServerSocketUtils.multiplex(chan)));
  }, onError: (Object e) async {
    print('error listening for channels: $e; will unpublish and try again');
    // this will close all channels under this psm
    await ble.unpublishL2capChannel(psm);
    unawaited(publishAndListen(ble));
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
        title: 'Flutter Demo - Peripheral SOCKS5 Server', home: MyHomePage(title: 'Flutter Demo - Peripheral SOCKS5 Server'));
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  _MyHomePageState() {
    loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: Text(widget.title),
        ),
        body: ListView.builder(
            itemCount: lines.length,
            itemBuilder: (BuildContext context, int index) {
              return SizedBox(
                child: Center(child: Text('Entry ${lines[index]}')),
              );
            }));
  }

  Future<void> loadData() async {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      setState(() {});
    }
  }
}
