// ignore_for_file: avoid_print, public_member_api_docs
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blev/ble.dart';
import 'package:blev/ble_central.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final thisGeneration = generation++;
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

        final List<L2CapChannel> chans = [];
        try {
          final chan1 = await periph.connectToL2CapChannel(psm);
          print('connected to chan 1');
          chans.add(chan1);

          if (periph.isMultipleChannelForPSMSupported) {
            final chan2 = await periph.connectToL2CapChannel(psm);
            print('connected to chan 2');
            chans.add(chan2);
          }
        } catch (error) {
          print('error connecting $error; will disconnect from peripheral and try again');
          await periph.disconnect();
          unawaited(connectAndTalk(ble));
          return;
        }

        Future<void> processChannel(L2CapChannel chan, int chanCount) async {
          final str = 'hello alice-$thisGeneration-$chanCount';
          while (true) {
            await Future<void>.delayed(const Duration(seconds: 1));
            try {
              print('writing');
              final written = await chan.write(Uint8List.fromList(str.codeUnits));
              print('wrote');
              if (written < 0) {
                break;
              }
              print('reading');
              final readBuf = await chan.read(256);
              print('read');
              if (readBuf == null) {
                print('EOF; done');
                return;
              }
              print('read on $chanCount: ${utf8.decode(readBuf)}');
            } catch (error) {
              print('$chanCount: error sending $error');
              break;
            }
          }
        }

        try {
          var chanNum = 0;
          final futs = chans.map((chan) {
            chanNum++;
            return processChannel(chan, chanNum);
          });
          await Future.wait(futs);
        } finally {
          print('closing ${chans.length} chans');
          for (var chan in chans) {
            await chan.close();
          }
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'Flutter Demo - Central (Bob)', home: MyHomePage(title: 'Flutter Demo - Central (Bob)'));
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
