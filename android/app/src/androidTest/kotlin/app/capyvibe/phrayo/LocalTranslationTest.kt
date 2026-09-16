package app.capyvibe.phrayo

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalTranslationTest {
    @Test fun explicitPreparationEnablesOfflineTranslation() = runBlocking {
        val translation = LocalTranslation()
        translation.prepare("en-US", "en-GB")
        withTimeout(120_000) { translation.prepare("en-US", "zh-CN") }
        assertEquals("installed", translation.status("en-US", "zh-CN"))
        assertTrue(translation.translate("Hello", "en-US", "zh-CN").contains("你好"))
        assertEquals("unsupported", translation.status("en-US", "yue-HK"))
    }
}
