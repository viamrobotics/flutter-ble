import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:blev/ble.dart';
import 'package:blev/ble_socket.dart';
import 'package:blev/src/ble_channel_socket_mux.dart';
import 'package:flutter/foundation.dart';
import 'package:test/test.dart';

void main() {
  test('Single client channel can be written to and read from', () async {
    final clientChannel = FakeL2CapChannel();
    final clientSocket = L2CapChannelClientSocketUtils.connectSingle(clientChannel);
    final ChunkedStreamReader<int> readTheWrites = ChunkedStreamReader<int>(clientChannel.writeController.stream);
    final ChunkedStreamReader<int> readTheReads = ChunkedStreamReader<int>(clientSocket);

    clientSocket.add([1, 2, 3]);
    clientSocket.add([4, 5, 6]);
    await clientSocket.flush();
    expect(await readTheWrites.readChunk(3), [1, 2, 3]);
    expect(await readTheWrites.readChunk(1), [4]);
    expect(await readTheWrites.readChunk(2), [5, 6]);

    clientChannel.readController.sink.add([7, 8, 9]);
    clientChannel.readController.sink.add([10, 11, 12]);
    expect(await readTheReads.readChunk(3), [7, 8, 9]);
    expect(await readTheReads.readChunk(1), [10]);
    expect(await readTheReads.readChunk(2), [11, 12]);

    expect(clientChannel.closed, 0);
    await clientSocket.close();
    expect(clientChannel.closed, 1);
  });

  test('Single server channel can be written to and read from', () async {
    final serverChannel = FakeL2CapChannel();
    final serverSocket = L2CapChannelServerSocketUtils.acceptSingle(serverChannel);
    final ChunkedStreamReader<int> readTheWrites = ChunkedStreamReader<int>(serverChannel.writeController.stream);

    final socket = await serverSocket.first;
    final ChunkedStreamReader<int> readTheReads = ChunkedStreamReader<int>(socket);

    socket.add([1, 2, 3]);
    socket.add([4, 5, 6]);
    await socket.flush();
    expect(await readTheWrites.readChunk(3), [1, 2, 3]);
    expect(await readTheWrites.readChunk(1), [4]);
    expect(await readTheWrites.readChunk(2), [5, 6]);

    serverChannel.readController.sink.add([7, 8, 9]);
    serverChannel.readController.sink.add([10, 11, 12]);
    expect(await readTheReads.readChunk(3), [7, 8, 9]);
    expect(await readTheReads.readChunk(1), [10]);
    expect(await readTheReads.readChunk(2), [11, 12]);

    expect(serverChannel.closed, 0);
    await socket.close();
    expect(serverChannel.closed, 1);
  });

  test('Multiplexed client can support multiple ports', () async {
    final clientChannel = FakeL2CapChannel();
    final clientSocketMux = L2CapChannelClientSocketUtils.multiplex(clientChannel);

    final clientSocket1 = clientSocketMux.connectSocket();
    clientSocketMux.connectSocket(); // do nothing with it
    final clientSocket2 = clientSocketMux.connectSocket();

    final ChunkedStreamReader<int> readTheWrites = ChunkedStreamReader<int>(clientChannel.writeController.stream);

    final ChunkedStreamReader<int> readTheReads1 = ChunkedStreamReader<int>(clientSocket1);
    final ChunkedStreamReader<int> readTheReads2 = ChunkedStreamReader<int>(clientSocket2);

    clientSocket1.add([1, 2, 3]);
    clientSocket2.add([4, 5, 6]);
    clientSocket1.add([7, 8, 9]);
    clientSocket2.add([10, 11, 12]);
    await clientSocket1.flush();
    await clientSocket2.flush();

    Future<Packet> nextPacket() async {
      while (true) {
        final pkt = await Packet.deserialize(readTheWrites);
        if (pkt == null || (pkt is ControlPacket && pkt.msgType == 0)) {
          continue;
        }
        return pkt;
      }
    }

    expect((await nextPacket()).serialize(), ControlPacket.socketOpen(1).serialize());
    expect((await nextPacket()).serialize(), ControlPacket.socketOpen(2).serialize());
    expect((await nextPacket()).serialize(), ControlPacket.socketOpen(3).serialize());
    expect((await nextPacket()).serialize(), DataPacket(1, Uint8List.fromList([1, 2, 3])).serialize());
    expect((await nextPacket()).serialize(), DataPacket(3, Uint8List.fromList([4, 5, 6])).serialize());
    expect((await nextPacket()).serialize(), DataPacket(1, Uint8List.fromList([7, 8, 9])).serialize());
    expect((await nextPacket()).serialize(), DataPacket(3, Uint8List.fromList([10, 11, 12])).serialize());

    clientChannel.readController.sink.add(DataPacket(1, Uint8List.fromList([13, 14, 15])).serialize());
    clientChannel.readController.sink.add(DataPacket(2, Uint8List.fromList([16, 17, 18])).serialize());
    // bad!
    clientChannel.readController.sink.add(ControlPacket.socketOpen(3).serialize());
    clientChannel.readController.sink.add(DataPacket(3, Uint8List.fromList([19, 20, 21])).serialize());
    expect(await readTheReads1.readChunk(3), [13, 14, 15]);
    expect(await readTheReads2.readChunk(3), [19, 20, 21]);

    await clientSocket1.close();
    expect(clientChannel.closed, 0);
    expect((await nextPacket()).serialize(), ControlPacket.socketClosed(1).serialize());

    await clientSocket2.close();
    expect(clientChannel.closed, 0);
    expect((await nextPacket()).serialize(), ControlPacket.socketClosed(3).serialize());

    await clientSocketMux.close();
    expect(clientChannel.closed, 1);
  });

  test('Multiplexed server can support multiple ports', () async {
    final serverChannel = FakeL2CapChannel();
    final serverSocketMux = L2CapChannelServerSocketUtils.multiplex(serverChannel);

    serverChannel.readController.sink.add(ControlPacket.socketOpen(1).serialize());
    serverChannel.readController.sink.add(ControlPacket.socketOpen(2).serialize());
    serverChannel.readController.sink.add(ControlPacket.socketOpen(3).serialize());

    final queue = StreamQueue<Socket>(serverSocketMux);
    final socket1 = await queue.next;
    await queue.next; // do nothing with it
    final socket2 = await queue.next;
    // must do this to fully close
    await queue.cancel();

    final ChunkedStreamReader<int> readTheWrites = ChunkedStreamReader<int>(serverChannel.writeController.stream);

    final ChunkedStreamReader<int> readTheReads1 = ChunkedStreamReader<int>(socket1);
    final ChunkedStreamReader<int> readTheReads2 = ChunkedStreamReader<int>(socket2);

    socket1.add([1, 2, 3]);
    socket2.add([4, 5, 6]);
    socket1.add([7, 8, 9]);
    socket2.add([10, 11, 12]);
    await socket1.flush();
    await socket2.flush();

    Future<Packet> nextPacket() async {
      while (true) {
        final pkt = await Packet.deserialize(readTheWrites);
        if (pkt == null || (pkt is ControlPacket && pkt.msgType == 0)) {
          continue;
        }
        return pkt;
      }
    }

    expect((await nextPacket()).serialize(), DataPacket(1, Uint8List.fromList([1, 2, 3])).serialize());
    expect((await nextPacket()).serialize(), DataPacket(3, Uint8List.fromList([4, 5, 6])).serialize());
    expect((await nextPacket()).serialize(), DataPacket(1, Uint8List.fromList([7, 8, 9])).serialize());
    expect((await nextPacket()).serialize(), DataPacket(3, Uint8List.fromList([10, 11, 12])).serialize());

    serverChannel.readController.sink.add(DataPacket(1, Uint8List.fromList([13, 14, 15])).serialize());
    serverChannel.readController.sink.add(DataPacket(2, Uint8List.fromList([16, 17, 18])).serialize());
    // bad!
    serverChannel.readController.sink.add(ControlPacket.socketOpen(3).serialize());
    serverChannel.readController.sink.add(DataPacket(3, Uint8List.fromList([19, 20, 21])).serialize());
    expect(await readTheReads1.readChunk(3), [13, 14, 15]);
    expect(await readTheReads2.readChunk(3), [19, 20, 21]);

    await socket1.close();
    expect(serverChannel.closed, 0);
    expect((await nextPacket()).serialize(), ControlPacket.socketClosed(1).serialize());

    await socket2.close();
    expect(serverChannel.closed, 0);
    expect((await nextPacket()).serialize(), ControlPacket.socketClosed(3).serialize());

    expect(serverChannel.closed, 0);
    await serverSocketMux.close();
    expect(serverChannel.closed, 1);
  });
}

class FakeL2CapChannel extends L2CapChannel {
  var closed = 0;
  final StreamController<List<int>> readController = StreamController();
  final StreamController<Uint8List> writeController = StreamController();
  late ChunkedStreamReader<int> _chunkedStreamReader;

  FakeL2CapChannel() {
    _chunkedStreamReader = ChunkedStreamReader<int>(readController.stream);
  }

  @override
  Future<int> write(Uint8List data) {
    writeController.add(data);
    return Future.value(data.length);
  }

  @override
  Future<Uint8List?> read(int maxRead) async {
    // this is silly to read just 1 but it satisfies this function easily
    final chunk = await _chunkedStreamReader.readChunk(1);
    return Future.value(Uint8List.fromList(chunk));
  }

  @override
  Future<void> close() {
    closed++;
    return readController.close();
  }
}
