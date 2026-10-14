package app.capyvibe.phrayo

import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.sin

class NativeContractsTest {
    @Test fun longVoiceTextRetainsAllCjkCharactersAndCompleteEndings() {
        val text = "今天天氣很好，我哋聽日再見。".repeat(40)
        val parts = VoiceTextSegments.split(text, "yue-HK")
        assertEquals(text, parts.joinToString(""))
        assertTrue(parts.all { it.length <= 32 })
        assertEquals("I'd like to book a table for two tomorrow evening.", VoiceTextSegments.split("I'd like to book a table for two tomorrow evening.", "en-US").single())
    }
    @Test fun resamplingPreservesChunkBoundariesAndDuration() {
        val input = FloatArray(48000) { sin(it * 0.04).toFloat() }
        val full = PcmResampler(48000).convert(input)
        val stream = PcmResampler(48000)
        val chunks = input.asList().chunked(2048).flatMap { stream.convert(it.toFloatArray()).asList() }.toFloatArray()
        assertEquals(16000, full.size)
        assertArrayEquals(full, chunks, 0f)
    }
    @Test fun cantoneseConfigurationDoesNotRequestMandarinTranslation() {
        val config = SonioxStream.configuration("test", "en-US", "yue-HK", emptyList())
        assertFalse(config.has("translation"))
        val source = SonioxStream.configuration("test", "yue-HK", "en-US", listOf("Phrayo"))
        assertEquals("zh", source.getJSONArray("language_hints").getString(0))
        assertEquals("Phrayo", source.getJSONObject("context").getJSONArray("terms").getString(0))
        assertTrue(source.getJSONObject("context").getJSONArray("general").toString().contains("Cantonese"))
    }
    @Test fun liveSonioxCharacterTokensAreGroupedIntoSentences() {
        val tokens = listOf(
            "{\"text\":\"我\",\"start_ms\":1000,\"end_ms\":1100}", "{\"text\":\"现\",\"start_ms\":1100,\"end_ms\":1200}",
            "{\"text\":\"在\",\"start_ms\":1200,\"end_ms\":1300}", "{\"text\":\"Now\",\"translation_status\":\"translation\"}",
            "{\"text\":\"说\",\"start_ms\":1300,\"end_ms\":1400}", "{\"text\":\"。\",\"start_ms\":1400,\"end_ms\":1450}",
            "{\"text\":\"好\",\"start_ms\":1500,\"end_ms\":1600,\"speaker\":1}", "{\"text\":\"的\",\"start_ms\":3500,\"end_ms\":3600,\"speaker\":1}",
            "{\"text\":\"<end>\"}").map { JSONObject(it) }
        val segments = SonioxStream.segments(tokens)
        assertEquals(listOf("我现在说。", "好", "的"), segments.map { it.text })
        assertEquals(1.0, segments.first().start, 0.0)
        assertEquals(1.45, segments.first().end, 1e-9)
        assertEquals("1", segments.last().speaker)
    }
    @Test fun malformedMossTimingFailsInsteadOfFabricatingSegments() {
        for (json in listOf("{\"segments\":[{\"text\":\"hello\",\"start\":3,\"end\":2}]}", "{\"text\":\"hello\"}", "{\"segments\":{}}")) {
            assertThrows(Exception::class.java) { MossTranscription.segments(JSONObject(json)) }
        }
        val result = MossTranscription.segments(JSONObject("{\"segments\":[{\"text\":\"hello\",\"start\":1,\"end\":2,\"speaker\":0}]}"))
        assertEquals(1.0, result.single().start, 0.0)
        assertEquals("0", result.single().speaker)
    }
    @Test fun heavyInferenceWaitsForRecordingAndRunsSerially() = runBlocking {
        val gate = InferenceGate(); gate.recording.value = true
        val order = mutableListOf<Int>()
        val first = async { gate.run { order.add(1); delay(30); order.add(2) } }
        val second = async { gate.run { order.add(3) } }
        delay(20); assertTrue(order.isEmpty())
        gate.recording.value = false
        first.await(); second.await()
        assertEquals(listOf(1, 2, 3), order)
    }
}
