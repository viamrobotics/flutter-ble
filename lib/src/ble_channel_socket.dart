import 'dart:io';

import 'package:async/async.dart';
import 'package:blev/src/ble.dart';
import 'package:blev/src/ble_channel_socket_mux.dart';
import 'package:blev/src/mixins.dart';
import 'package:flutter/foundation.dart';

/// Client side utilities for L2CAP channels as sockets.
///
/// L2CapChannelClientSocketUtils can be used on either a central or peripheral to
/// create single or multiplexed sockets for one l2cap channel. The type
/// of single or multiplexed must be matched by both sides. For example,
/// if the central uses L2CapChannelClientSocketUtils.multiplex then
/// the peripheral must use L2CapChannelServerSocketUtils.multiplex.
///
/// For more information on multiplexing, see [Multiplexing Connections](https://github.com/viamrobotics/flutter-ble/blob/main/doc/sockets.md#multiplexing-connections).
class L2CapChannelClientSocketUtils {
  /// Creates an exclusive socket for one channel.
  ///
  /// The socket now owns the channel.
  static Socket connectSingle(L2CapChannel channel) => _L2CapChannelSocket(channel);

  /// Creates a client side multiplexed socket over one channel.
  ///
  /// The multiplexer now owns the channel.
  static L2CapChannelClientSocketMultiplexer multiplex(L2CapChannel channel) => L2CapChannelClientSocketMultiplexer(channel);
}

/// Server side utilities for L2CAP channels as sockets.
///
/// L2CapChannelServerSocketUtils can be used on either a central or peripheral to
/// accept single or multiplexed sockets for one l2cap channel. The type
/// of single or multiplexed must be matched by both sides. For example,
/// if the central uses L2CapChannelClientSocketUtils.multiplex then
/// the peripheral must use L2CapChannelServerSocketUtils.multiplex.
///
/// For more information on multiplexing, see [Multiplexing Connections](https://github.com/viamrobotics/flutter-ble/blob/main/doc/sockets.md#multiplexing-connections).
class L2CapChannelServerSocketUtils {
  /// Creates an exclusive socket for one channel that will only accept once.
  ///
  /// The socket now owns the channel.
  static ServerSocket acceptSingle(L2CapChannel channel) => _L2CapChannelServerSocket.single(channel);

  /// Creates a server side multiplexed socket over one channel.
  ///
  /// The multiplexer now owns the channel.
  static ServerSocket multiplex(L2CapChannel channel) => _L2CapChannelServerSocket.multiplexed(channel);
}

/// _L2CapChannelSocket is used for a 1:1 channel:socket.
///
/// For multiplexing, use _L2CapChannelStreamedSocket in conjunction with a socket multiplexer.
class _L2CapChannelSocket with StreamFromControllerMixin<Uint8List>, IOSinkFromControllerMixin implements Socket {
  final L2CapChannel _channel;
  final CancelableCompleter<void> _completer = CancelableCompleter<void>();

  _L2CapChannelSocket(this._channel) {
    _read();
    _write();
  }

  Future<void> _read() async {
    try {
      while (!_completer.isCompleted) {
        final data = await _channel.read(256);
        if (data == null) {
          return;
        }
        streamController.sink.add(data);
      }
    } catch (err) {
      debugPrint('error reading from l2cap channel: $err');
    } finally {
      await streamController.sink.close();
    }
  }

  Future<void> _write() async {
    try {
      await for (final data in ioSinkController.stream) {
        if (_completer.isCompleted) {
          return;
        }
        await _channel.write(Uint8List.fromList(data));
      }
    } catch (err) {
      debugPrint('error writing to l2cap channel: $err');
    }
  }

  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  @override
  void destroy() {
    _completer.complete();
    streamController.close();
  }

  @override
  Uint8List getRawOption(RawSocketOption option) {
    throw UnimplementedError();
  }

  /// The port used by this socket.
  ///
  /// It's always 1234 and should not matter.
  @override
  int get port => 1234;

  @override
  InternetAddress get remoteAddress => InternetAddress.anyIPv4;

  @override
  int get remotePort => 4321;

  @override
  // we don't support any options which may cause semantic issues in the future?
  bool setOption(SocketOption option, bool enabled) {
    if (option == SocketOption.tcpNoDelay) {
      debugPrint('_L2CapChannelSocket ignoring setOption for tcpNoDelay=$enabled');
    } else {
      debugPrint('_L2CapChannelSocket ignoring setOption');
    }
    return false;
  }

  @override
  // we don't support any options which may cause semantic issues in the future?
  void setRawOption(RawSocketOption option) {
    debugPrint('_L2CapChannelSocket ignoring setRawOption $option');
  }

  @override
  Future<void> close() async {
    destroy();
    await super.close();
    await _channel.close();
  }
}

class _L2CapChannelServerSocket with StreamFromControllerMixin<Socket> implements ServerSocket {
  final Future<void> Function()? _onClose;
  Future<dynamic>? _streamFut;

  _L2CapChannelServerSocket._private(this._onClose);

  // This will simply return one socket on its stream and close itself.
  factory _L2CapChannelServerSocket.single(L2CapChannel channel) {
    final socket = _L2CapChannelServerSocket._private(null);
    socket.streamController.sink.add(_L2CapChannelSocket(channel));
    socket.streamController.close();
    return socket;
  }

  factory _L2CapChannelServerSocket.multiplexed(L2CapChannel channel) {
    final multiplexer = L2CapChannelServerSocketMultiplexer(channel);
    final socket = _L2CapChannelServerSocket._private(multiplexer.close);
    socket._streamFut = socket.streamController.sink.addStream(multiplexer.sockets);
    return socket;
  }

  /// The port used by this socket.
  ///
  /// It's always 1234 and should not matter.
  @override
  int get port => 1234;

  /// The address used by this socket.
  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  /// Closes the socket.
  ///
  /// The returned future completes when the socket
  /// is fully closed and is no longer bound.
  @override
  Future<ServerSocket> close() {
    Future<void> fut = Future.value(null);
    if (_onClose != null) {
      fut = _onClose!();
    }
    if (_streamFut != null) {
      fut = fut.then((_) => streamController.close());
    }
    return fut.then((_) => this);
  }
}
