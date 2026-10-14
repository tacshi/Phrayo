package app.capyvibe.phrayo

import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun Call.awaitResponse(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) { if (continuation.isActive) continuation.resumeWithException(error) }
        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response) { _, value, _ -> value.close() }
        }
    })
}

internal data class SpeechResult(val text: String, val translation: String, val segments: List<SegmentMessage>)

internal class SonioxStream(key: String, source: String, target: String, terms: List<String>,
    private val changed: (SpeechResult) -> Unit) {
    private val done = CompletableDeferred<SpeechResult>()
    private val finals = mutableListOf<JSONObject>()
    private var latest = SpeechResult("", "", emptyList())
    private val sending = Any()
    private val pending = ArrayList<ByteArray>()
    private var pendingBytes = 0
    private var opened = false
    private var ending = false
    private val socket = client.newWebSocket(Request.Builder().url("wss://stt-rt.soniox.com/transcribe-websocket").build(),
        object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                synchronized(sending) {
                    webSocket.send(configuration(key, source, target, terms).toString())
                    pending.forEach { webSocket.send(it.toByteString()) }
                    pending.clear(); pendingBytes = 0; opened = true
                    if (ending) webSocket.send("")
                }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val payload = JSONObject(text)
                    if (payload.has("error_code")) problem("soniox_failed")
                    val rows = payload.optJSONArray("tokens") ?: JSONArray()
                    val tokens = (0 until rows.length()).map { rows.getJSONObject(it) }
                    finals.addAll(tokens.filter { it.optBoolean("is_final") })
                    latest = render(finals + tokens.filter { !it.optBoolean("is_final") })
                    changed(latest)
                    if (payload.optBoolean("finished")) done.complete(latest)
                } catch (error: Exception) { done.completeExceptionally(error); webSocket.cancel() }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { done.completeExceptionally(t) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!done.isCompleted) done.completeExceptionally(FlutterError("soniox_failed", null, null))
            }
        })
    // Sixty seconds of short-session audio cannot grow this queue beyond 2 MiB.
    fun append(bytes: ByteArray) = synchronized(sending) {
        if (done.isCompleted) return
        if (!opened) {
            pendingBytes += bytes.size
            if (pendingBytes <= 2 * 1024 * 1024) { pending.add(bytes); return }
        }
        if (!opened || socket.queueSize() > 2 * 1024 * 1024 || !socket.send(bytes.toByteString())) {
            done.completeExceptionally(FlutterError("soniox_failed", null, null)); socket.cancel()
        }
    }
    suspend fun finish(): SpeechResult = try {
        append(ByteArray(6400)); synchronized(sending) { ending = true; if (opened) socket.send("") }
        withTimeout(20_000) { done.await() }
    } finally { socket.close(1000, null) }
    fun cancel() { done.cancel(); socket.cancel() }
    companion object {
        private val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.SECONDS).build()
        fun configuration(key: String, source: String, target: String, terms: List<String>): JSONObject {
            fun code(value: String) = languageCode(value).let { if (it == "yue") "zh" else it }
            val config = JSONObject().put("api_key", key).put("model", "stt-rt-v5")
                .put("audio_format", "pcm_s16le").put("sample_rate", 16000).put("num_channels", 1)
                .put("language_hints", JSONArray(listOf(code(source)))).put("enable_language_identification", true)
            if (code(source) != code(target) && languageCode(target) != "yue") {
                config.put("translation", JSONObject().put("type", "one_way").put("target_language", code(target)))
            }
            val context = JSONObject()
            if (terms.isNotEmpty()) context.put("terms", JSONArray(terms))
            if (languageCode(source) == "yue") context.put("general", JSONArray(listOf(
                JSONObject().put("key", "language").put("value", "Cantonese (Hong Kong)"),
                JSONObject().put("key", "instructions").put("value", "Preserve colloquial Cantonese wording in Traditional Chinese characters."))))
            if (context.length() > 0) config.put("context", context)
            return config
        }
        private fun render(tokens: List<JSONObject>): SpeechResult {
            val text = StringBuilder(); val translation = StringBuilder()
            tokens.forEach { token ->
                val value = token.optString("text")
                if (!value.startsWith("<")) {
                    if (token.optString("translation_status") == "translation") translation.append(value)
                    else text.append(value)
                }
            }
            return SpeechResult(text.toString(), translation.toString(), segments(tokens))
        }
        private val sentenceEnd = Regex("[。！？.!?]\\s*$")
        // Chinese and Japanese tokens are often single characters, so group them into sentences.
        // Keep the boundaries aligned with sonioxSegments in services/transcription.dart.
        fun segments(tokens: List<JSONObject>): List<SegmentMessage> {
            val result = mutableListOf<SegmentMessage>()
            val text = StringBuilder(); var start: Double? = null; var end = 0.0; var speaker: String? = null
            fun flush() {
                val value = text.trim().toString()
                start?.let { if (value.isNotEmpty()) result.add(SegmentMessage("segment-${result.size}", value, it, end, speaker)) }
                text.clear(); start = null
            }
            for (token in tokens) {
                val value = token.optString("text")
                if (value.startsWith("<") || token.optString("translation_status") == "translation") continue
                val from = token.optDouble("start_ms"); val to = token.optDouble("end_ms")
                if (!from.isFinite() || !to.isFinite() || from < 0 || to < from) continue
                val who = if (token.isNull("speaker")) null else token.get("speaker").toString()
                if (start != null && (who != speaker || from / 1000 - end > 1.5)) flush()
                speaker = who; if (start == null) start = from / 1000; end = to / 1000
                text.append(value)
                if (sentenceEnd.containsMatchIn(value)) flush()
            }
            flush()
            return result
        }
    }
}

internal class MossTranscription(private val key: String) {
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(30, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()
    private suspend fun request(path: List<String>, body: RequestBody? = null, delete: Boolean = false): JSONObject {
        val url = "https://api.mosi.cn/v1/".toHttpUrl().newBuilder().apply { path.forEach { addPathSegment(it) } }.build()
        val request = Request.Builder().url(url).header("Authorization", "Bearer $key").apply {
            if (delete) delete() else if (body != null) post(body)
        }.build()
        return client.newCall(request).awaitResponse().use { response ->
            if (delete && response.code == 404) return@use JSONObject()
            if (!response.isSuccessful) problem(when (response.code) {
                401, 402, 403 -> "auth_error"; 413 -> "moss_file_too_large"; 429 -> "rate_limit"; else -> "network_error"
            })
            if (delete) JSONObject() else withContext(Dispatchers.IO) { JSONObject(response.body!!.string()) }
        }
    }
    suspend fun run(audio: File, job: JSONObject, persist: () -> Unit): List<SegmentMessage> {
        if (job.optString("stage") in setOf("submission_unknown", "upload_unknown")) problem("moss_submission_unknown")
        if (!job.has("fileId")) {
            if (audio.length() > 512L * 1024 * 1024) problem("moss_file_too_large")
            val body = MultipartBody.Builder().setType(MultipartBody.FORM).addFormDataPart("purpose", "audio")
                .addFormDataPart("file", "recording.m4a", audio.asRequestBody("audio/mp4".toMediaType())).build()
            job.put("stage", "upload_unknown"); persist()
            val response = request(listOf("files"), body)
            val id = response.optString("id").takeIf { it.isNotEmpty() } ?: problem("invalid_response")
            job.put("fileId", id).put("stage", "uploaded"); persist()
        }
        if (!job.has("remoteId")) {
            val payload = JSONObject().put("model", job.getString("model")).put("file_id", job.getString("fileId"))
                .put("diarize", true).put("response_format", "json").put("async", true)
            job.optJSONArray("transcriptionTerms")?.takeIf { it.length() > 0 }?.let { payload.put("keyterms", it) }
            job.put("stage", "submission_unknown"); persist()
            val response = request(listOf("audio", "transcriptions"), payload.toString().toRequestBody("application/json".toMediaType()))
            val id = response.optString("task_id", response.optString("id")).takeIf { it.isNotEmpty() } ?: problem("invalid_response")
            job.put("remoteId", id).put("stage", "processing"); persist()
        }
        while (true) {
            val response = request(listOf("audio", "tasks", job.getString("remoteId")))
            when (response.optString("status").uppercase()) {
                "SUCCESS", "COMPLETED" -> return segments(response)
                "FAILED", "FAILURE", "ERROR" -> { job.put("stage", "remote_failed"); persist(); problem("moss_transcription_failed") }
                "PENDING", "QUEUED", "PROCESSING", "RUNNING" -> delay((response.optDouble("retry_after", 3.0).coerceIn(1.0, 30.0) * 1000).toLong())
                else -> problem("invalid_response")
            }
        }
    }
    suspend fun cleanup(job: JSONObject) { job.stringOrNull("fileId")?.let { request(listOf("files", it), delete = true) } }
    companion object {
        fun segments(payload: JSONObject): List<SegmentMessage> {
            fun seconds(value: Double): Double = value.takeIf { it.isFinite() && it >= 0 } ?: problem("invalid_response")
            if (payload.has("segments") && payload.optJSONArray("segments") == null) problem("invalid_response")
            val rows = payload.optJSONArray("segments") ?: JSONArray()
            val result = (0 until rows.length()).mapNotNull { index ->
                val row = rows.getJSONObject(index); val text = row.getString("text").trim()
                if (text.isEmpty()) null else {
                    val start = seconds(row.getDouble("start")); val end = seconds(row.getDouble("end"))
                    if (end < start) problem("invalid_response")
                    SegmentMessage("moss-$index", text, start, end, if (row.isNull("speaker")) null else row.get("speaker").toString())
                }
            }
            if (result.isNotEmpty()) return result
            val text = payload.optString("text").trim().takeIf { it.isNotEmpty() } ?: problem("no_speech")
            return listOf(SegmentMessage("moss-0", text, 0.0, seconds(payload.getDouble("duration")), null))
        }
    }
}
