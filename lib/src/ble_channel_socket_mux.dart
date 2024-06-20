import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:ble/src/ble.dart';
import 'package:ble/src/mixins.dart';
import 'package:flutter/foundation.dart';

/// A socket multiplexer that owns the underlying L2CapChannel.
abstract class _L2CapChannelSocketMultiplexer {
  final L2CapChannel _channel;
  final Map<int, _L2CapChannelStreamedSocket> _portToSocket = {};
  final CancelableCompleter<void> _completer = CancelableCompleter<void>();

  // see close
  // ignore: close_sinks
  final StreamController<List<int>> _channelReadController = StreamController();
  final StreamController<Packet> _channelWriteController = StreamController();
  late ChunkedStreamReader<int> _chunkedStreamReader;

  void Function(Socket)? get _onNewSocket;
  var nextPort = 0;

  _L2CapChannelSocketMultiplexer(this._channel) {
    _chunkedStreamReader = ChunkedStreamReader<int>(_channelReadController.stream);

    // read from the actual network...
    _pipeChanReadsIntoChunks();

    // ...into our opened sockets.
    _readChunksToSockets();

    // pipe writes from the sockets into the network
    _pipeWritesIntoChan();

    _sendKeepAliveFramesForever();
  }

  Future<void> _pipeChanReadsIntoChunks() async {
    try {
      while (!_completer.isCompleted) {
        final data = await _channel.read(256);
        if (data == null) {
          return;
        }
        _channelReadController.sink.add(data.toList());
      }
    } catch (err) {
      if (!_completer.isCompleted) {
        debugPrint('error piping reads from l2cap channel into chunks: $err');
      }
    } finally {
      await close();
    }
  }

  Future<void> _readChunksToSockets() async {
    try {
      while (!_completer.isCompleted) {
        final pkt = await Packet.deserialize(_chunkedStreamReader);
        if (pkt == null) {
          // dropped
          continue;
        }
        if (pkt is DataPacket) {
          // not even sure why this lint happens here
          // ignore: close_sinks
          final socket = _portToSocket[pkt.port];
          if (pkt.data.isEmpty) {
            continue;
          }

          if (socket == null) {
            debugPrint('unknown port ${pkt.port}; dropping packet');
            continue;
          }
          socket.streamController.sink.add(pkt.data);
        } else if (pkt is ControlPacket) {
          if (pkt.msgType == 0) {
            // keep alive
            continue;
          }
          if (pkt.msgType != 1) {
            debugPrint('do not know how to handle MSG_TYPE ${pkt.msgType}; dropping packet');
            continue;
          }

          // port status
          switch (pkt.status) {
            case 0: // closed
              await _portToSocket[pkt.forPort]?.streamController.sink.close();
              _portToSocket.remove(pkt.forPort);
            case 1: // open
              // not even sure why this lint happens here
              // ignore: close_sinks
              final socket = _portToSocket[pkt.forPort];
              if (socket == null) {
                if (_onNewSocket == null) {
                  debugPrint('invariant: expected _onNewSocket to be set if we got a connection open control message');
                } else {
                  _onNewSocket!(_createNewSocket(pkt.forPort));
                }
              } else {
                debugPrint('connection on port ${pkt.forPort} already open; dropping packet');
              }
            default:
              debugPrint('do not know how to handle FOR_PORT ${pkt.forPort} STATUS ${pkt.status}; dropping packet');
          }
        } else {
          debugPrint('do not know how to handle packet $pkt; dropping packet');
        }
      }
    } catch (err) {
      if (!_completer.isCompleted) {
        debugPrint('error reading chunks into sockets: $err');
      }
      await close();
    }
  }

  Future<void> _pipeWritesIntoChan() async {
    try {
      await for (final pkt in _channelWriteController.stream) {
        if (_completer.isCompleted) {
          return;
        }
        await _channel.write(pkt.serialize());
      }
    } catch (err) {
      if (!_completer.isCompleted) {
        debugPrint('error piping writes into l2cap channel: $err');
      }
      await close();
    }
  }

  Future<void> _sendKeepAliveFramesForever() async {
    final pkt = ControlPacket.keepAlive().serialize();
    try {
      while (!_completer.isCompleted) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await _channel.write(pkt);
      }
    } catch (err) {
      if (!_completer.isCompleted) {
        debugPrint('error sending keep alive frames into l2cap channel: $err');
      }
      await close();
    }
  }

  _L2CapChannelStreamedSocket _createNewSocket(int? requestedPort) {
    if (_completer.isCompleted) {
      throw Exception('closed');
    }

    // find the next port to use
    final int thisPort;
    if (requestedPort == null) {
      // increment at least once
      for (var i = 0; i < _portToSocket.length + 1; i++) {
        if (nextPort + 1 > 65535) {
          nextPort = 0;
        }
        nextPort++;
        if (!_portToSocket.containsKey(nextPort)) {
          break;
        }
      }
      if (_portToSocket.containsKey(nextPort)) {
        throw Exception('too many open connections');
      }
      thisPort = nextPort;
    } else {
      if (_portToSocket.containsKey(requestedPort)) {
        throw Exception('connection on $requestedPort should not be open yet');
      }
      thisPort = requestedPort;
    }

    final socket = _L2CapChannelStreamedSocket(thisPort);
    _portToSocket[thisPort] = socket;

    // client MUST disclose its port first with a CONTROL packet.
    // the client doing this is an arbitrary choice in the protocol.
    // Note: the ports are the same on both sides so we just "open"
    // in on direction. This may be a bad choice but since this is
    // already encapsulated over ble, we don't need much of a concept
    // of listening and ephemeral ports.
    if (requestedPort == null) {
      // clients call this function not knowing what port they want
      _channelWriteController.add(ControlPacket.socketOpen(thisPort));
    }

    socket.ioSinkController.stream.listen((data) {
      _channelWriteController.add(DataPacket(thisPort, Uint8List.fromList(data)));
    }, onDone: () {
      _channelWriteController.add(ControlPacket.socketClosed(thisPort));
      _portToSocket.remove(thisPort);
    }, onError: (error) {
      _channelWriteController.add(ControlPacket.socketClosed(thisPort));
      _portToSocket.remove(thisPort);
    });
    return socket;
  }

  Future<void> close() async {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete();
    for (var socket in _portToSocket.values) {
      socket.destroy();
    }
    _portToSocket.clear();
    await _channelReadController.sink.close();
    await _channel.close();
  }
}

/// A client side socket multiplexer over one L2CAP channel.
class L2CapChannelClientSocketMultiplexer extends _L2CapChannelSocketMultiplexer {
  /// Create a client multiplexer for the given channel.
  L2CapChannelClientSocketMultiplexer(super.channel);

  @override
  void Function(Socket)? get _onNewSocket => null;

  /// Connect a single socket.
  ///
  /// Note: This immediately returns.
  Socket connectSocket() {
    return _createNewSocket(null);
  }
}

/// A server side socket multiplexer over one L2CAP channel.
class L2CapChannelServerSocketMultiplexer extends _L2CapChannelSocketMultiplexer {
  final StreamController<Socket> _socketController = StreamController();

  /// A stream of accepted sockets.
  Stream<Socket> get sockets => _socketController.stream;

  /// Create a server multiplexer for the given channel.
  L2CapChannelServerSocketMultiplexer(super.channel);

  @override
  void Function(Socket)? get _onNewSocket => (socket) => _socketController.add(socket);

  @override
  Future<void> close() async {
    await super.close();
    await _socketController.close();
  }
}

/// A packet encapsulating data for multiplexed sockets.
///
/// For more information on the packet structure and protocol, see [Multiplexing Connections](https://github.com/viamrobotics/flutter-ble/blob/main/doc/sockets.md#multiplexing-connections).
abstract class Packet {
  /// Deserializes until a Packet is read or dropped.
  static Future<Packet?> deserialize(ChunkedStreamReader<int> reader) async {
    var bytes = await reader.readChunk(2);
    if (bytes.length != 2) {
      throw Exception('expected 2 bytes for PORT but got ${bytes.length}');
    }
    final port = Uint8List.fromList(bytes).buffer.asByteData().getUint16(0, Endian.little);

    if (port == 0) {
      bytes = await reader.readChunk(1);
      if (bytes.length != 1) {
        throw Exception('expected 1 bytes for MSG_TYPE length but got ${bytes.length}');
      }
      final msgType = Uint8List.fromList(bytes).buffer.asByteData().getUint8(0);
      if (msgType == 0) {
        return ControlPacket.keepAlive();
      }
      if (msgType != 1) {
        debugPrint('do not know how to handle MSG_TYPE $msgType');
        return null;
      }

      bytes = await reader.readChunk(2);
      if (bytes.length != 2) {
        throw Exception('expected 1 bytes for FOR_PORT length but got ${bytes.length}');
      }
      final forPort = Uint8List.fromList(bytes).buffer.asByteData().getUint16(0, Endian.little);

      bytes = await reader.readChunk(1);
      if (bytes.length != 1) {
        throw Exception('expected 1 bytes for STATUS length but got ${bytes.length}');
      }
      final status = Uint8List.fromList(bytes).buffer.asByteData().getUint8(0);

      switch (status) {
        case 0:
          return ControlPacket.socketClosed(forPort);
        case 1:
          return ControlPacket.socketOpen(forPort);
        default:
          debugPrint('do not know how to handle FOR_PORT $forPort STATUS $status');
          return null;
      }
    }

    bytes = await reader.readChunk(4);
    if (bytes.length != 4) {
      throw Exception('expected 4 bytes for DATA length but got ${bytes.length}');
    }
    final dataLen = Uint8List.fromList(bytes).buffer.asByteData().getUint32(0, Endian.little);

    if (dataLen == 0) {
      return DataPacket(port, Uint8List(0));
    }

    bytes = await reader.readChunk(dataLen);
    if (bytes.length != dataLen) {
      throw Exception('expected $dataLen bytes for DATA length but got ${bytes.length}');
    }
    return DataPacket(port, Uint8List.fromList(bytes));
  }

  /// Serializes the packet.
  Uint8List serialize();
}

/// A packet of data for a multiplexed socket on a specific port.
class DataPacket extends Packet {
  /// The src/dst port (they are the same).
  int port;

  /// The encapsulated data.
  Uint8List data;

  /// A packet with data for a port.
  DataPacket(this.port, this.data);

  /*
    +------+-----+------+
    | PORT | LEN | DATA |
    +------+-----+------+
    |   2  |  4  | LEN  |
    +------+-----+------+
  */
  @override
  Uint8List serialize() {
    if (data.length > 4294967295) {
      throw Exception('data too large to send ${data.length}');
    }
    final lengthAndData = Uint8List(2 + 4 + data.length);
    lengthAndData.buffer.asByteData().setUint16(0, port, Endian.little);
    lengthAndData.buffer.asByteData().setUint32(2, data.length, Endian.little);
    lengthAndData.setAll(6, data);
    return lengthAndData;
  }
}

/// A control packet for the multiplexer.
class ControlPacket extends Packet {
  /// The type of message (either Keep Alive=0 or Port Status=1)
  int msgType;

  /// The port the message is for is msgType=1.
  int forPort;

  /// The status (closed=0, open=1).
  int status;

  /// The underlying data for the packet.
  Uint8List rawData;

  /// A control packet with all possible fields specified.
  ControlPacket(this.msgType, this.forPort, this.status, this.rawData);

  @override
  Uint8List serialize() {
    return rawData;
  }

  /// A Keep Alive packet.
  /*
    Keep Alive

    +------+----------+
    | PORT | MSG_TYPE |
    +------+----------+
    | 2=0  |  1=0     |
    +------+----------+
  */
  factory ControlPacket.keepAlive() {
    final data = Uint8List(3);
    data.buffer.asByteData().setUint16(0, 0, Endian.little);
    data.buffer.asByteData().setUint8(2, 0);
    return ControlPacket(0, 0, 0, data);
  }

  /// A connection closed status packet.
  /*
    Connection Status

    +------+----------+----------+--------+
    | PORT | MSG_TYPE | FOR_PORT | STATUS |
    +------+----------+----------+--------+
    | 2=0  |  1=1     | 2        |    1   |
    +------+----------+----------+--------+

    3 bytes for:
    Port, Status

    Status 0 = Closed
    Status 1 = Open
  */

  factory ControlPacket.socketClosed(int portNumber) {
    final data = Uint8List(6);
    data.buffer.asByteData().setUint16(0, 0, Endian.little);
    data.buffer.asByteData().setUint8(2, 1);
    data.buffer.asByteData().setUint16(3, portNumber, Endian.little);
    data.buffer.asByteData().setUint8(5, 0);
    return ControlPacket(1, portNumber, 0, data);
  }

  /// A connection open status packet.
  /*
    Connection Status

    +------+----------+----------+--------+
    | PORT | MSG_TYPE | FOR_PORT | STATUS |
    +------+----------+----------+--------+
    | 2=0  |  1=1     | 2        |    1   |
    +------+----------+----------+--------+

    3 bytes for:
    Port, Status

    Status 0 = Closed
    Status 1 = Open
  */

  factory ControlPacket.socketOpen(int portNumber) {
    final data = Uint8List(6);
    data.buffer.asByteData().setUint16(0, 0, Endian.little);
    data.buffer.asByteData().setUint8(2, 1);
    data.buffer.asByteData().setUint16(3, portNumber, Endian.little);
    data.buffer.asByteData().setUint8(5, 1);
    return ControlPacket(1, portNumber, 1, data);
  }
}

// _L2CapChannelStreamedSocket delegates its reads and writes to a socket
// multiplexer like L2CapChannelServerSocketMultiplexer or L2CapChannelClientSocketMultiplexer.
class _L2CapChannelStreamedSocket with StreamFromControllerMixin<Uint8List>, IOSinkFromControllerMixin implements Socket {
  final int _port;

  _L2CapChannelStreamedSocket(this._port);

  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  @override
  void destroy() {
    streamController.close();
  }

  // Note(erd): this may be needed. Saw this once
  // error connecting NoSuchMethodError: Class '__L2CapChannelStreamedSocket' has no instance method '_detachRaw'
  //Future<RawSecureSocket> _detachRaw() {}

  @override
  Uint8List getRawOption(RawSocketOption option) {
    throw UnimplementedError();
  }

  @override
  int get port => _port;

  @override
  InternetAddress get remoteAddress => InternetAddress.anyIPv4;

  @override
  int get remotePort => _port;

  @override
  // we don't support any options which may cause semantic issues in the future?
  bool setOption(SocketOption option, bool enabled) {
    if (option == SocketOption.tcpNoDelay) {
      debugPrint('_L2CapChannelStreamedSocket ignoring setOption for tcpNoDelay=$enabled');
    } else {
      debugPrint('_L2CapChannelStreamedSocket ignoring setOption');
    }
    return false;
  }

  @override
  // we don't support any options which may cause semantic issues in the future?
  void setRawOption(RawSocketOption option) {
    debugPrint('_L2CapChannelStreamedSocket ignoring setRawOption $option');
  }

  @override
  Future<void> close() async {
    destroy();
    await super.close();
  }
}
