package com.macandroid.filemanager

import com.macandroid.filemanager.runtime.SessionStateTracker
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class SessionStateTrackerTest {

    private var fakeTime = 100_000L

    @Before
    fun setUp() {
        fakeTime = 100_000L
        SessionStateTracker.timeSource = { fakeTime }
        SessionStateTracker.resetForTesting()
    }

    @After
    fun tearDown() {
        SessionStateTracker.timeSource = { android.os.SystemClock.elapsedRealtime() }
    }

    @Test
    fun testInitialState() {
        assertEquals(0, SessionStateTracker.activeSftpSessions)
        assertFalse(SessionStateTracker.isConnected)
        assertFalse(SessionStateTracker.isTransferring)
    }

    @Test
    fun testSessionOpenAndClose() {
        var notifiedCurrent = -1
        var notifiedPrevious = -1

        val listener = SessionStateTracker.SessionCountListener { cur, prev ->
            notifiedCurrent = cur
            notifiedPrevious = prev
        }
        SessionStateTracker.addListener(listener)

        // 0 -> 1
        val c1 = SessionStateTracker.onSessionOpened()
        assertEquals(1, c1)
        assertEquals(1, SessionStateTracker.activeSftpSessions)
        assertTrue(SessionStateTracker.isConnected)
        assertEquals(1, notifiedCurrent)
        assertEquals(0, notifiedPrevious)

        // 1 -> 2
        val c2 = SessionStateTracker.onSessionOpened()
        assertEquals(2, c2)
        assertEquals(2, SessionStateTracker.activeSftpSessions)
        assertEquals(2, notifiedCurrent)
        assertEquals(1, notifiedPrevious)

        // 2 -> 1
        val c3 = SessionStateTracker.onSessionClosed()
        assertEquals(1, c3)
        assertEquals(1, SessionStateTracker.activeSftpSessions)
        assertEquals(1, notifiedCurrent)
        assertEquals(2, notifiedPrevious)

        // 1 -> 0
        val c4 = SessionStateTracker.onSessionClosed()
        assertEquals(0, c4)
        assertEquals(0, SessionStateTracker.activeSftpSessions)
        assertFalse(SessionStateTracker.isConnected)
        assertEquals(0, notifiedCurrent)
        assertEquals(1, notifiedPrevious)

        // Clamp at 0 (extra close)
        val c5 = SessionStateTracker.onSessionClosed()
        assertEquals(0, c5)
        assertEquals(0, SessionStateTracker.activeSftpSessions)
    }

    @Test
    fun testRecordIoAndTransferringState() {
        assertEquals(0L, SessionStateTracker.lastIoElapsedRealtime)

        SessionStateTracker.onSessionOpened()
        SessionStateTracker.recordIo()

        assertTrue("После recordIo время должно быть зафиксировано", SessionStateTracker.lastIoElapsedRealtime > 0L)
        assertTrue("При наличии сессий и недавнем I/O isTransferring == true", SessionStateTracker.isTransferring)

        // Проверяем устаревание I/O (> 30 секунд)
        fakeTime += 35_000L
        assertFalse("Спустя 35 с без I/O isTransferring == false", SessionStateTracker.isTransferring)
        assertTrue("Но соединение всё ещё активно", SessionStateTracker.isConnected)

        SessionStateTracker.onSessionClosed()
        assertFalse("При отсутствии сессий isTransferring == false", SessionStateTracker.isTransferring)
    }
}
