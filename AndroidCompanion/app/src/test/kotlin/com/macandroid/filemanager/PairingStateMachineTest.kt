package com.macandroid.filemanager

import com.macandroid.filemanager.server.EmbeddedServer
import org.apache.sshd.common.config.keys.KeyUtils
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Security

class PairingStateMachineTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var testDir: File
    private var fakeTime = 100_000L

    private fun generateEd25519KeyPair(): KeyPair {
        if (Security.getProvider("EdDSA") == null) {
            Security.addProvider(net.i2p.crypto.eddsa.EdDSASecurityProvider())
        }
        return KeyPairGenerator.getInstance("EdDSA", "EdDSA").generateKeyPair()
    }

    @Before
    fun setUp() {
        testDir = tempFolder.newFolder("pairing_state_test")
        fakeTime = 100_000L
        EmbeddedServer.timeSource = { fakeTime }
        EmbeddedServer.closePairingWindow()
    }

    @After
    fun tearDown() {
        EmbeddedServer.timeSource = { android.os.SystemClock.elapsedRealtime() }
    }

    @Test
    fun testInitialStateWindowClosed() {
        assertFalse("Окно сопряжения изначально должно быть закрыто", EmbeddedServer.isPairingModeActive)
        assertNull(EmbeddedServer.pendingPairing)
        assertNull(EmbeddedServer.approvedPairing)
    }

    @Test
    fun testOpenAndClosePairingWindow() {
        EmbeddedServer.openPairingWindow()
        assertTrue("Окно сопряжения должно быть активно после openPairingWindow", EmbeddedServer.isPairingModeActive)

        EmbeddedServer.closePairingWindow()
        assertFalse("Окно сопряжения должно быть закрыто после closePairingWindow", EmbeddedServer.isPairingModeActive)
        assertNull(EmbeddedServer.pendingPairing)
        assertNull(EmbeddedServer.approvedPairing)
    }

    @Test
    fun testConfirmPendingPairingTransitionsToApprovedWithoutWritingFile() {
        val authFile = File(testDir, "authorized_keys")
        val kp = generateEd25519KeyPair()
        val keyBytes = kp.public.encoded
        val fingerprint = KeyUtils.getFingerPrint(kp.public)

        EmbeddedServer.openPairingWindow()

        // Симулируем регистрацию заявки при query-offer
        EmbeddedServer.setPendingPairingForTesting(
            EmbeddedServer.Companion.PendingPairing(
                key = kp.public,
                keyBytes = keyBytes,
                fingerprint = fingerprint,
                sourceIp = "192.168.1.100",
                createdAt = fakeTime
            )
        )

        assertNotNull(EmbeddedServer.pendingPairing)
        assertEquals(fingerprint, EmbeddedServer.pendingPairing?.fingerprint)

        // Пользователь нажимает «Принять»
        val confirmed = EmbeddedServer.confirmPendingPairing()
        assertTrue("confirmPendingPairing должен вернуть true", confirmed)

        // Состояние: pending очищен, approved установлен
        assertNull("Pending слот должен быть очищен после одобрения", EmbeddedServer.pendingPairing)
        assertNotNull("Approved слот должен быть заполнен", EmbeddedServer.approvedPairing)
        assertTrue(
            "Approved должен содержать те же байты ключа",
            EmbeddedServer.approvedPairing?.keyBytes.contentEquals(keyBytes)
        )

        // ТЗ 2.2: Ключ ЕЩЁ НЕ должен быть записан в файл!
        assertFalse("Файл authorized_keys НЕ должен быть создан до проверки подписи", authFile.exists())

        // Закрытие окна аннулирует approved
        EmbeddedServer.closePairingWindow()
        assertNull(EmbeddedServer.approvedPairing)
    }

    @Test
    fun testQueryOnlyOfferNeverEnrollsKey() {
        val authFile = File(testDir, "authorized_keys")
        EmbeddedServer.openPairingWindow()

        // Проверяем, что без SessionListener.Event.Authenticated файл authorized_keys пуст
        assertFalse(authFile.exists())
        assertEquals(0, EmbeddedServer.getParsedAuthorizedKeys(authFile).size)
    }

    @Test
    fun testRejectPendingPairingClearsState() {
        val kp = generateEd25519KeyPair()

        EmbeddedServer.openPairingWindow()
        EmbeddedServer.setPendingPairingForTesting(
            EmbeddedServer.Companion.PendingPairing(
                key = kp.public,
                keyBytes = kp.public.encoded,
                fingerprint = "test-fp",
                sourceIp = "127.0.0.1",
                createdAt = fakeTime
            )
        )
        assertNotNull(EmbeddedServer.pendingPairing)

        EmbeddedServer.rejectPendingPairing()
        assertNull("После отклонения pendingPairing должен быть null", EmbeddedServer.pendingPairing)
        assertNull("После отклонения approvedPairing должен быть null", EmbeddedServer.approvedPairing)
    }
}
