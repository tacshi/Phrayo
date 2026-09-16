package app.capyvibe.phrayo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class OfflineSpeechTest {
    @Test fun installedSenseVoiceDecodesTheEnglishFixtureWithTiming() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val fixture = File(context.filesDir, "fixtures/en.wav")
        assumeTrue("Stage the pinned SenseVoice test fixture before running this test", fixture.isFile)
        val engine = OfflineSpeech(context, InferenceGate())
        engine.prepare("en-US")
        assertEquals("ready", engine.status("en-US"))
        assertEquals("unsupported", engine.status("fr-FR"))
        val result = engine.transcribe(fixture, "en-US")
        assertTrue(result.toString(), result.joinToString(" ") { it.text }.lowercase().contains("tribal chieftain"))
        assertTrue(result.all { it.start >= 0 && it.end > it.start })
        assertEquals("unsupported", LocalTranslation().status("yue-HK", "en-US"))
    }
}
