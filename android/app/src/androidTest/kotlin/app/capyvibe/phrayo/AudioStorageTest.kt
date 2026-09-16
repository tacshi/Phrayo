package app.capyvibe.phrayo

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.sin

@RunWith(AndroidJUnit4::class)
class AudioStorageTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun recoveredCaptureExportsAllSegmentsAndCanBeDecoded() = runBlocking {
        val files = AudioFiles(context); val id = UUID.randomUUID().toString(); val folder = files.folder(id).apply { mkdirs() }
        try {
            writeJson(File(folder, "capture.json"), JSONObject().put("rate", 48000))
            repeat(3) { chunk ->
                val raw = ByteBuffer.allocate(48000 * 2).order(ByteOrder.LITTLE_ENDIAN)
                repeat(48000) { raw.putShort((sin((chunk * 48000 + it) * 0.06) * 16000).toInt().toShort()) }
                File(folder, "%06d.pcm".format(chunk)).writeBytes(raw.array())
            }
            files.save(SessionMessage(id = id, kind = "recording", state = "recording", seconds = 3.0,
                level = 0.0, transcript = "", translation = "", segments = emptyList()))
            val recovered = files.recover().single { it.id == id }
            assertEquals("interrupted", recovered.state)
            val output = AudioCodec.ensureAudio(files.audio(recovered.path!!))
            assertTrue(output.length() > 1000)
            assertFalse(folder.listFiles()!!.any { it.extension == "pcm" })
            var samples = 0
            AudioCodec.decode(output) { block -> assertTrue(block.all(Float::isFinite)); samples += block.size }
            assertTrue("Decoded $samples samples", samples in 47500..50000)
            assertEquals(output, AudioCodec.ensureAudio(output))
            files.acknowledge(id)
            assertFalse(files.recover().any { it.id == id })
        } finally { folder.deleteRecursively() }
    }
    @Test fun audioPathsRejectTraversalForeignFilesAndSymlinks() {
        val files = AudioFiles(context); val id = UUID.randomUUID().toString()
        assertEquals(File(files.folder(id), "recording.m4a"), files.audio("$id/recording.m4a"))
        for (path in listOf("../recording.m4a", "$id/../recording.m4a", "/sdcard/$id/recording.m4a", "$id/session.json")) {
            assertThrows(FlutterError::class.java) { files.audio(path) }
        }
        val link = File(files.root, id)
        try {
            Os.symlink(context.cacheDir.path, link.path)
            assertThrows(FlutterError::class.java) { files.audio("$id/recording.m4a") }
        } finally { link.delete() }
    }
    @Test fun credentialsAreEncryptedAndCanBeRemoved() {
        val storage = context.createDeviceProtectedStorageContext()
        val preferences = storage.getSharedPreferences("credentials", 0)
        val original = preferences.getString("soniox", null)
        try {
            val secrets = SecretStore(storage)
            secrets.save("soniox", "fixture-not-a-real-secret")
            assertEquals("fixture-not-a-real-secret", secrets.read("soniox"))
            assertFalse(preferences.getString("soniox", "")!!.contains("fixture"))
            secrets.save("soniox", ""); assertNull(secrets.read("soniox"))
        } finally { preferences.edit().putString("soniox", original).commit() }
    }
}
