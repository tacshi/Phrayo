package app.capyvibe.phrayo

import android.content.Intent
import android.app.KeyguardManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecordingLifecycleTest {
    @Test fun pauseResumeStopAndConcurrentDiscardPreserveSessionOwnership() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeFalse("Unlock the phone for microphone tests", context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        for (permission in listOf("RECORD_AUDIO", "POST_NOTIFICATIONS")) {
            instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.$permission").close()
        }
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        delay(500)
        val host = withContext(Dispatchers.Main) { AndroidHost.get(context) }
        val events = host.events
        withContext(Dispatchers.Main) { host.events = null }
        val owned = mutableListOf<String>()
        try {
            val first = withContext(Dispatchers.Main) { host.start("recording", "en-US", "en-US", true, "soniox", emptyList()) }
            owned.add(first.id)
            delay(700)
            val beforePause = withContext(Dispatchers.Main) { host.pause(); host.snapshot()!!.seconds }
            delay(300)
            withContext(Dispatchers.Main) { assertEquals(beforePause, host.snapshot()!!.seconds, 0.1); host.resume() }
            delay(400)
            val stopped = withContext(Dispatchers.Main) {
                val one = async { host.stop() }; val two = async { host.stop() }
                assertEquals(one.await().id, two.await().id); one.await()
            }
            assertEquals("saved", stopped.state)
            assertTrue(stopped.seconds >= 0.5)
            val output = AudioFiles(context).audio(stopped.path!!)
            assertTrue(output.isFile)
            val second = withContext(Dispatchers.Main) { host.start("practice", "en-US", "en-US", true, "soniox", emptyList()) }
            owned.add(second.id)
            delay(250)
            withContext(Dispatchers.Main) {
                val stopping = async { runCatching { host.stop() } }
                host.cancel(); stopping.await()
                assertEquals("cancelled", host.snapshot()!!.state)
                assertEquals(second.id, host.snapshot()!!.id)
            }
            assertFalse(AudioFiles(context).folder(second.id).exists())
            assertTrue(output.isFile)
        } finally {
            withContext(Dispatchers.Main) { host.cancel(); owned.forEach { AudioFiles(context).folder(it).deleteRecursively() }; host.events = events; activity.finish() }
        }
    }
}
