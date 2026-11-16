package com.macandroid.filemanager

import com.macandroid.filemanager.runtime.DaemonLog
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class DaemonLogTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun testTrimLogFile() {
        val testFile = tempFolder.newFile("test_daemon.log")

        // Создаём файл размером ~300 КБ
        val sb = StringBuilder()
        for (i in 0 until 6000) {
            sb.append("2026-11-16T22:00:00.000+01:00 Event message line $i\n")
        }
        testFile.writeText(sb.toString(), Charsets.UTF_8)
        assertTrue("Размер файла должен быть > 256 КБ", testFile.length() > 256 * 1024)

        DaemonLog.trim(testFile)

        assertTrue("Размер файла после trim должен быть <= 128 КБ", testFile.length() <= 128 * 1024 + 500)
        assertTrue("Файл не должен быть пуст", testFile.length() > 0)

        // Проверяем, что первая строка целая (не оборвана в середине)
        val firstLine = testFile.readLines().firstOrNull()
        assertNotNull(firstLine)
        assertTrue("Первая строка должна начинаться с даты", firstLine!!.startsWith("2026-11-16T"))
    }
}
