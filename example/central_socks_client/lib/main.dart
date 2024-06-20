// ignore_for_file: avoid_print, public_member_api_docs
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble/ble.dart';
import 'package:ble/ble_central.dart';
import 'package:ble/ble_socket.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socks5_proxy/socks.dart';

List<String> lines = [];

void main() {
  runZoned(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      Permission.bluetoothScan.request().then((status) => Permission.bluetoothConnect.request()).then((status) {
        BleCentral.create().then((ble) {
          final stateStream = ble.getState();
          late StreamSubscription<AdapterState> streamSub;
          streamSub = stateStream.listen((state) {
            if (state == AdapterState.poweredOn) {
              streamSub.cancel();
              connectAndTalk(ble);
            }
          });
        }).catchError((error) {
          print('error requesting bluetooth permissions $error');
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

Future<void> connectAndTalk(BleCentral ble) async {
  const testSvcUUID = '00000000-0000-1234-0001-000000000000';
  const testPSMCharUUID = '00000000-0000-1234-0001-000000000001';
  const wantedDeviceName = 'TestBT1';

  print('will scan for device now');
  late StreamSubscription<DiscoveredBlePeripheral> deviceSub;
  deviceSub = ble.scanForPeripherals([testSvcUUID]).listen(
    (periphInfo) {
      if (periphInfo.name == wantedDeviceName) {
        print('found device; connecting...');
        deviceSub.cancel();
      } else {
        return;
      }
      ble.connectToPeripheral(periphInfo.id).then((periph) async {
        print('connected to peripheral');

        final char = periph.services
            .cast<BleService?>()
            .firstWhere((svc) => svc!.id == testSvcUUID, orElse: () => null)
            ?.characteristics
            .cast<BleCharacteristic?>()
            .firstWhere((char) => char!.id == testPSMCharUUID);
        if (char == null) {
          print('did not find needed PSM char after discovery');
          await Future<void>.delayed(const Duration(seconds: 1));
          print('will disconnect from peripheral and try again');
          await periph.disconnect();
          unawaited(connectAndTalk(ble));
          return;
        }

        Uint8List? val;
        try {
          val = await char.read();
        } catch (error) {
          print('error reading characteristic $error; will disconnect from peripheral and try again');
          await periph.disconnect();
          unawaited(connectAndTalk(ble));
          return;
        }
        final psm = int.parse(utf8.decode(val!));
        print('will connect to channel on psm: $psm');

        final L2CapChannel chan;
        try {
          chan = await periph.connectToL2CapChannel(psm);
          print('connected');
        } catch (error) {
          print('error connecting $error; will disconnect from peripheral and try again');
          await periph.disconnect();
          unawaited(connectAndTalk(ble));
          return;
        }

        final socketMux = L2CapChannelClientSocketUtils.multiplex(chan);
        print('multiplexed the channel');

        try {
          while (true) {
            final List<Socket> connectedSockets = [];
            try {
              await IOOverrides.runZoned(() {
                return makeRequests();
              }, socketConnect: (host, int port, {sourceAddress, int sourcePort = 0, Duration? timeout}) {
                final connectedSocket = socketMux.connectSocket();
                connectedSockets.add(connectedSocket);
                return Future.value(connectedSocket);
              });
            } catch (error) {
              print('error doing request $error');
              rethrow;
            } finally {
              for (var socket in connectedSockets) {
                await socket.close();
              }
            }
          }
        } finally {
          await chan.close();
          print('will disconnect from peripheral and try again');
          await periph.disconnect();
          unawaited(connectAndTalk(ble));
        }
      }).catchError((error) {
        print('error connecting $error; will try again');
        unawaited(connectAndTalk(ble));
      });
    },
    onError: (Object e) => print('connectAndTalk failed: $e'),
  );
}

Future<void> makeRequests() async {
  final client = HttpClient();
  client.userAgent = 'curl/8.6.0';

  SocksTCPClient.assignToHttpClient(client, [
    ProxySettings(InternetAddress.loopbackIPv4, 1080),
  ]);

  const url = 'http://ifconfig.io';

  try {
    await Future<void>.delayed(const Duration(seconds: 4));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final decoded = await utf8.decodeStream(response);
      print('got ${decoded.length} bytes');
      print(decoded);
    }
  } finally {
    client.close();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
        title: 'Flutter Demo - Central SOCKS5 Client', home: MyHomePage(title: 'Flutter Demo - Central SOCKS5 Client'));
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
