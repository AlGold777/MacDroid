package com.macandroid.filemanager

import com.macandroid.filemanager.server.CustomSftpEventListener
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContractTest {

    @Test
    fun testValidPartFilesMatchContract() {
        // 1. .<name>.mcdpart
        assertTrue(CustomSftpEventListener.isPartFile(".photo.jpg.mcdpart"))
        assertTrue(CustomSftpEventListener.isPartFile(".video.mp4.mcdpart"))
        assertTrue(CustomSftpEventListener.isPartFile(".archive.tar.gz.mcdpart"))

        // 2. <name>.mcdpart
        assertTrue(CustomSftpEventListener.isPartFile("photo.jpg.mcdpart"))
        assertTrue(CustomSftpEventListener.isPartFile("video.mp4.mcdpart"))

        // 3. .part.<actionId>.<name>
        assertTrue(CustomSftpEventListener.isPartFile(".part.12345.document.pdf"))
        assertTrue(CustomSftpEventListener.isPartFile(".part.act_abc.image.png"))

        // 4. .<name>.part
        assertTrue(CustomSftpEventListener.isPartFile(".download.iso.part"))
    }

    @Test
    fun testUserFilesDoNotMatchContract() {
        // ТЗ 5.3: Переименование пользовательского файла с "part" в середине не должно триггерить хук
        assertFalse("my.part.notes.txt не является временным файлом", CustomSftpEventListener.isPartFile("my.part.notes.txt"))
        assertFalse("part1.txt не является временным файлом", CustomSftpEventListener.isPartFile("part1.txt"))
        assertFalse("some.part.doc не является временным файлом", CustomSftpEventListener.isPartFile("some.part.doc"))
        assertFalse("normal_file.txt не является временным файлом", CustomSftpEventListener.isPartFile("normal_file.txt"))
        assertFalse("photo.jpg не является временным файлом", CustomSftpEventListener.isPartFile("photo.jpg"))
        assertFalse("empty string", CustomSftpEventListener.isPartFile(""))
    }
}
