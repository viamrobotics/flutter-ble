package com.viam.ble

import android.bluetooth.BluetoothSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class L2CAPChannel(
    private val socket: BluetoothSocket,
    private val onClose: (suspend () -> Unit),
) {
    private val writeMutex = Mutex()
    private val readMutex = Mutex()

    @Volatile
    private var isClosed = false

    suspend fun write(message: ByteArray) {
        if (isClosed) {
            throw Exception("channel closed")
        }
        withContext(Dispatchers.IO) {
            writeMutex.withLock {
                socket.outputStream.write(message)
            }
        }
    }

    suspend fun read(maxRead: Int): ByteArray? {
        if (isClosed) {
            throw Exception("channel closed")
        }
        return withContext(Dispatchers.IO) {
            readMutex.withLock {
                val buf = ByteArray(maxRead)
                val bytesRead = socket.inputStream.read(buf)
                if (bytesRead == -1) {
                    return@withContext null
                }
                return@withContext buf.sliceArray(0 until bytesRead)
            }
        }
    }

    suspend fun close() {
        if (isClosed) {
            return
        }
        isClosed = true

        // guarded by isClosed volatile
        withContext(Dispatchers.IO) {
            socket.outputStream.close()
            socket.inputStream.close()
            socket.close()
        }
        onClose.invoke()
    }
}
