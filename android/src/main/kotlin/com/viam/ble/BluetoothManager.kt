package com.viam.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.IOException
import java.lang.ref.WeakReference

abstract class BluetoothManager(
    internal val context: WeakReference<Context>,
) : Closeable {
    internal val btMan: BluetoothManager =
        context.get()?.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val stateJob: Job

    val state: Int
        get() = btMan.adapter.state

    init {
        stateJob =
            CoroutineScope(Dispatchers.IO).launch {
                delay(1000)
                _stateFlow.emit(state)
            }
    }

    @Throws(IOException::class)
    override fun close() {
        stateJob.cancel("manager closed")
    }

    private val _stateFlow = MutableSharedFlow<Int>(replay = 0)
    val stateFlow: SharedFlow<Int> = _stateFlow

    // This should be called for all methods that would expect the power to be on. Not calling this
    // won't cause any bad state but we may not return the best errors as a result.
    internal suspend fun mustBePoweredOn() {
        withContext(Dispatchers.IO) {
            if (state != BluetoothAdapter.STATE_ON) {
                throw Exception("must be powered on first before calling any non-state methods")
            }
        }
    }
}
