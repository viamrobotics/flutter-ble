package com.viam.ble

import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class L2CAPChannelManager(
    private val serverSocket: BluetoothServerSocket? = null,
) {
    private var channels: MutableMap<Int, L2CAPChannel> = mutableMapOf()
    private val channelsMutex = Mutex()

    @Volatile
    private var isClosed = false
    private val _channelOpenedFlow = MutableSharedFlow<Int>(replay = 0)
    val channelOpenedFlow: SharedFlow<Int> = _channelOpenedFlow

    private var nextCID = 0 // this is our own concept of CID

    suspend fun getChannel(cid: Int): L2CAPChannel? {
        return withContext(Dispatchers.IO) {
            channelsMutex.withLock {
                return@withContext channels[cid]
            }
        }
    }

    suspend fun handleNewChannel(socket: BluetoothSocket): Int {
        channelsMutex.withLock {
            // increment at least once
            for (i in 0 until channels.size + 1) {
                nextCID =
                    try {
                        Math.addExact(nextCID, 1)
                    } catch (ex: ArithmeticException) {
                        0
                    }
                if (!channels.containsKey(nextCID)) {
                    break
                }
            }
            if (channels.containsKey(nextCID)) {
                throw Exception("too many channels open")
            }
            val thisCID = nextCID
            val chan =
                L2CAPChannel(socket) {
                    channelsMutex.withLock {
                        channels.remove(thisCID)
                    }
                }
            channels[thisCID] = chan
            _channelOpenedFlow.emit(thisCID)
            return thisCID
        }
    }

    suspend fun close() {
        if (isClosed) {
            return
        }
        isClosed = true

        // guarded by isClosed volatile
        withContext(Dispatchers.IO) {
            val readCopy =
                channelsMutex.withLock {
                    val copy = channels.values.toList()
                    channels.clear()
                    return@withLock copy
                }
            readCopy.forEach {
                it.close()
            }
            serverSocket?.close()
        }
    }
}
