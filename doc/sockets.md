# Sockets Abstraction

By default, the package provides simple reader writer abstraction for an L2CAP COC. Depending on the application, you may actually need a `Socket`. For this, the `ble_socket` library provides client and server wrappers for a single `Socket` with `L2CapChannelClientSocketUtils.connectSingle` and `L2CapChannelServerSocketUtils.acceptSingle` respectively. This is useful if you need just one `Socket` that a client doing a `connect` would create or a server `accept`ing once.

## Multiplexing Connections

In more complicated applications, you may want to use a single L2CAP channel to service multiple connections/sockets. This is helpful in some case like:
* when you may be limited to just one channel (like iOS centrals are)
* you want to reduce the overhead of BLE L2CAP connection establishment
* you want to share flow control credits for one connection at large

For clients, you can multiplex multiple sockets/connections with `L2CapChannelClientSocketUtils.multiplex`. For servers, `L2CapChannelServerSocketUtils.multiplex`. Which side of a BLE connection is a client or server does not matter, but each side must pick either client or server role, but not both.

### Protocol

The general idea of the protocol is that it is a client/server abstraction. Clients open connections on ports; servers accept these connections. The client dictates the port and the server utilizes the same port. Normally a client and server would use port pairs for both source and destination, but this is an encapsulated protocol over BLE. We're assuming that for each L2CAP COC on a particular PSM, that the two sides are part of the same user application such that dedicated ports are not necessary. If that assumption ever changes, this protocol would need to accommodate that. Therefore, the name "port" is a weak abstraction over traditional ports and should be thought to be synonymous  with a connection. Connection ID was rejected as the name because CID is too close to a BLE CID and it'd likely add confusion.

When a client or server wants to close a connection, it must send a Connection Status CONTROL packet indicating the connection on the port is closed.

The protocol uses dynamically sized packets to transmit data and control information which are described below.

#### DATA Packets

DATA packets MUST only be sent on open connections (see Port Status).

Layout:
```
+------+-----+------+
| PORT | LEN | DATA |
+------+-----+------+
|   2  |  4  | LEN  |
+------+-----+------+
```

#### CONTROL Packets

CONTROL packets are always on port 0 so that we can share the first 2 bytes of DATA packets. They are followed by a MSG_TYPE field that determines what data follows.


##### Keep Alive

Keep alives MUST be sent at some interval which SHOULD be every second from both sides. This helps keep an idle BLE connection open.

Layout:
```
+------+----------+
| PORT | MSG_TYPE |
+------+----------+
| 2=0  |  1=0     |
+------+----------+
```


##### Connection Status

Connection status packets are used to open and close connections. You MUST open a connection on a port before writing to it. The client MUST choose a non-zero 16-bit unsigned integer port. Port zero is reserved for CONTROL packets.

Layout:
```
+------+----------+----------+--------+
| PORT | MSG_TYPE | FOR_PORT | STATUS |
+------+----------+----------+--------+
| 2=0  |  1=1     | 2        |    1   |
+------+----------+----------+--------+

3 bytes for:
Port, Status

Status 0 = Closed
Status 1 = Open
```
