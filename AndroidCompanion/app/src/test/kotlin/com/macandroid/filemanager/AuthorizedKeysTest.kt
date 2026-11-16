package com.macandroid.filemanager

import com.macandroid.filemanager.server.EmbeddedServer
import org.apache.sshd.common.config.keys.KeyUtils
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Security
import java.util.Base64

class AuthorizedKeysTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var testDir: File

    private fun generateEd25519KeyPair(): KeyPair {
        if (Security.getProvider("EdDSA") == null) {
            Security.addProvider(net.i2p.crypto.eddsa.EdDSASecurityProvider())
        }
        return KeyPairGenerator.getInstance("EdDSA", "EdDSA").generateKeyPair()
    }

    @Before
    fun setUp() {
        testDir = tempFolder.newFolder("companion_keys_test")
    }

    @Test
    fun testParseOpenSshFormat() {
        val kp = generateEd25519KeyPair()
        val openSshLine = EmbeddedServer.openSshLineFor(kp.public)

        assertTrue("OpenSSH строка должна начинаться с ssh-ed25519", openSshLine.startsWith("ssh-ed25519"))
        val parsed = EmbeddedServer.parseSingleAuthorizedKey(openSshLine)
        assertNotNull("Ключ должен успешно разбираться", parsed)
        assertTrue("Разобранный ключ должен совпадать с исходным", KeyUtils.compareKeys(kp.public, parsed))
    }

    @Test
    fun testParseLegacyRawBase64Format() {
        val kp = generateEd25519KeyPair()
        val base64Key = Base64.getEncoder().encodeToString(kp.public.encoded)

        val parsed = EmbeddedServer.parseSingleAuthorizedKey(base64Key)
        assertNotNull("Legacy Base64 DER ключ должен разбираться", parsed)
        assertTrue("Разобранный ключ должен совпадать с исходным", KeyUtils.compareKeys(kp.public, parsed!!) || kp.public.encoded.contentEquals(parsed.encoded))
    }

    @Test
    fun testParseInvalidKeyReturnsNull() {
        assertNull(EmbeddedServer.parseSingleAuthorizedKey(""))
        assertNull(EmbeddedServer.parseSingleAuthorizedKey("   "))
        assertNull(EmbeddedServer.parseSingleAuthorizedKey("invalid-garbage-data-not-a-key"))
        assertNull(EmbeddedServer.parseSingleAuthorizedKey("ssh-ed25519 with\nnewline"))
    }

    @Test
    fun testIsKeyAuthorized() {
        val authFile = File(testDir, "authorized_keys")
        val kp1 = generateEd25519KeyPair()
        val kp2 = generateEd25519KeyPair()

        // Файл не существует -> false
        assertFalse(EmbeddedServer.isKeyAuthorized(kp1.public, authFile))

        // Записываем kp1
        val line1 = EmbeddedServer.openSshLineFor(kp1.public)
        authFile.writeText(line1 + "\n")

        assertTrue("Сохранённый ключ должен быть авторизован", EmbeddedServer.isKeyAuthorized(kp1.public, authFile))
        assertFalse("Несохранённый ключ не должен быть авторизован", EmbeddedServer.isKeyAuthorized(kp2.public, authFile))
    }

    @Test
    fun testIsPairedRequiresValidParsedKey() {
        val authFile = File(testDir, "authorized_keys")

        // Пустой файл или мусор: раньше длина > 0 давала true (#22), теперь должен требоваться валидный ключ
        authFile.writeText("some garbage text\n")
        val parsed = EmbeddedServer.getParsedAuthorizedKeys(authFile)
        assertTrue("Мусор не должен давать валидных ключей", parsed.isEmpty())

        // Записываем настоящий ключ
        val kp = generateEd25519KeyPair()
        val line = EmbeddedServer.openSshLineFor(kp.public)
        authFile.writeText(line + "\n")

        val validKeys = EmbeddedServer.getParsedAuthorizedKeys(authFile)
        assertEquals(1, validKeys.size)
        assertTrue(KeyUtils.compareKeys(kp.public, validKeys[0]))
    }

    @Test
    fun testAtomicWriteAuthorizedKeys() {
        val authFile = File(testDir, "authorized_keys")
        val kp1 = generateEd25519KeyPair()
        val kp2 = generateEd25519KeyPair()

        val line1 = EmbeddedServer.openSshLineFor(kp1.public)
        val line2 = EmbeddedServer.openSshLineFor(kp2.public)

        assertTrue(EmbeddedServer.writeAuthorizedKeyAtomic(testDir, line1))
        assertTrue(authFile.exists())
        assertEquals(1, EmbeddedServer.getParsedAuthorizedKeys(authFile).size)

        // Добавляем второй ключ
        assertTrue(EmbeddedServer.writeAuthorizedKeyAtomic(testDir, line2))
        val keys = EmbeddedServer.getParsedAuthorizedKeys(authFile)
        assertEquals(2, keys.size)

        // Повторное добавление существующего ключа не дублирует
        assertTrue(EmbeddedServer.writeAuthorizedKeyAtomic(testDir, line1))
        assertEquals(2, EmbeddedServer.getParsedAuthorizedKeys(authFile).size)

        // Временный файл не должен оставаться
        val tmp = File(testDir, "authorized_keys.tmp")
        assertFalse(tmp.exists())
    }
}
