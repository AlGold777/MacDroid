package com.macandroid.filemanager.runtime

import android.os.SystemClock
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * Единый in-process трекер состояния SFTP-сессий (ТЗ 4.1).
 * Процессный синглтон, устраняет IPC-интенты (ACTION_ACTIVE_SYNC_START/STOP) из NIO-потоков.
 */
object SessionStateTracker {

    private val _sftpSessions = AtomicInteger(0)

    @Volatile
    var timeSource: () -> Long = { SystemClock.elapsedRealtime() }

    @Volatile
    var lastIoElapsedRealtime: Long = 0L
        private set

    @Volatile
    var generation: Long = 0L
        private set

    val activeSftpSessions: Int
        get() = _sftpSessions.get()

    /**
     * Различает состояние CONNECTED (сессия открыта, но нет активного I/O)
     * и TRANSFERRING (был файловый I/O за последние 30 секунд).
     */
    val isTransferring: Boolean
        get() {
            if (activeSftpSessions <= 0) return false
            val lastIo = lastIoElapsedRealtime
            if (lastIo <= 0L) return false
            return (timeSource() - lastIo) < 30_000L
        }

    val isConnected: Boolean
        get() = activeSftpSessions > 0

    fun interface SessionCountListener {
        fun onSessionCountChanged(activeSessions: Int, previousSessions: Int)
    }

    private val listeners = CopyOnWriteArrayList<SessionCountListener>()

    fun addListener(listener: SessionCountListener) {
        listeners.add(listener)
    }

    fun removeListener(listener: SessionCountListener) {
        listeners.remove(listener)
    }

    /**
     * Вызывается из CustomSftpEventListener.initialized при открытии SFTP-сессии.
     */
    fun onSessionOpened(): Int {
        generation++
        val prev = _sftpSessions.getAndIncrement()
        val current = prev + 1
        notifyListeners(current, prev)
        return current
    }

    /**
     * Вызывается из CustomSftpEventListener.destroying при закрытии SFTP-сессии.
     */
    fun onSessionClosed(): Int {
        generation++
        var prev: Int
        var current: Int
        do {
            prev = _sftpSessions.get()
            current = if (prev > 0) prev - 1 else 0
        } while (!_sftpSessions.compareAndSet(prev, current))

        notifyListeners(current, prev)
        return current
    }

    /**
     * Фиксация файлового I/O (чтение/запись в CustomSftpEventListener).
     */
    fun recordIo() {
        lastIoElapsedRealtime = timeSource()
    }

    private fun notifyListeners(current: Int, previous: Int) {
        for (listener in listeners) {
            try {
                listener.onSessionCountChanged(current, previous)
            } catch (e: Exception) {
                android.util.Log.w("SessionStateTracker", "Ошибка в SessionCountListener", e)
            }
        }
    }

    /**
     * Сброс для тестов.
     */
    internal fun resetForTesting() {
        _sftpSessions.set(0)
        lastIoElapsedRealtime = 0L
        generation = 0L
        listeners.clear()
    }
}
