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
      Permission.bluetoothScan
          .request()
          .then((status) => Permission.bluetoothConnect.request())
          .then((status) {
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
  print('will scan for device now');
  late StreamSubscription<DiscoveredBlePeripheral> deviceSub;
  deviceSub = ble.scanForPeripherals([]).listen(
    (periphInfo) {
      print('found device; ${periphInfo.name}');
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
        title: 'Flutter Demo - Central (Bob)',
        home: MyHomePage(title: 'Flutter Demo - Central (Bob)'));
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
