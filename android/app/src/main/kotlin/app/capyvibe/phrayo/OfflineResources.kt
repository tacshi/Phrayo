package app.capyvibe.phrayo

import android.content.Context
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.*
import com.k2fsa.sherpa.onnx.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

internal data class ModelFile(val name: String,val bytes: Long,val sha256: String,val url: String)

internal class ModelStore(context: Context, val id: String, val files: List<ModelFile>) {
    val directory=File(context.noBackupFilesDir,"models/$id")
    private val staging=File(context.noBackupFilesDir,"models/.$id")
    private val mutex=Mutex()
    private val client=OkHttpClient.Builder().connectTimeout(30,TimeUnit.SECONDS).readTimeout(30,TimeUnit.SECONDS).build()
    @Volatile private var active: okhttp3.Call?=null
    private val fingerprint=files.joinToString("\n") { "${it.name}:${it.bytes}:${it.sha256}" }
    fun installed(): Boolean = runCatching {
        File(directory,"verified").readText()==fingerprint && files.all { File(directory,it.name).length()==it.bytes }
    }.getOrDefault(false)
    fun invalidate() { File(directory,"verified").delete() }
    fun cancel() { active?.cancel() }
    private suspend fun matches(file: File, spec: ModelFile): Boolean {
        if (!file.isFile || file.length()!=spec.bytes) return false
        val digest=MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer=ByteArray(1024*1024)
            while (true) { currentCoroutineContext().ensureActive(); val n=input.read(buffer); if(n<0) break; digest.update(buffer,0,n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }==spec.sha256
    }
    suspend fun prepare(progress: (Double)->Unit = {}, validate: suspend (File)->Unit) = mutex.withLock {
        if (installed()) return@withLock
        withContext(Dispatchers.IO) {
            staging.mkdirs()
            val total=files.sumOf { it.bytes }
            var completed=0L
            for (spec in files) {
                currentCoroutineContext().ensureActive()
                val file=File(staging,spec.name)
                if (!matches(file,spec)) {
                    val prior=File(directory,spec.name)
                    if (matches(prior,spec)) prior.copyTo(file,true) else {
                        val partial=File(staging,"${spec.name}.part")
                        if (partial.length()>spec.bytes) partial.delete()
                        val offset=partial.length()
                        val request=Request.Builder().url(spec.url).apply { if(offset>0) header("Range","bytes=$offset-") }.build()
                        val call=client.newCall(request); active=call
                        try {
                            call.execute().use { response ->
                                val append=response.code==206 && offset>0
                                if (!response.isSuccessful || (append && response.header("Content-Range")?.startsWith("bytes $offset-")!=true)) problem("network_error")
                                var received=if(append) offset else 0
                                FileOutputStream(partial,append).use { output ->
                                    response.body!!.byteStream().use { input ->
                                        val buffer=ByteArray(256*1024)
                                        while(true) {
                                            currentCoroutineContext().ensureActive()
                                            val n=input.read(buffer); if(n<0) break
                                            received+=n; if(received>spec.bytes) problem("invalid_response")
                                            output.write(buffer,0,n); progress((completed+received).toDouble()/total)
                                        }
                                    }
                                    output.fd.sync()
                                }
                            }
                        } finally { active=null }
                        if (!matches(partial,spec)) { partial.delete(); problem("model_download_failed") }
                        if (!partial.renameTo(file)) problem("model_download_failed")
                    }
                }
                File(staging,"${spec.name}.part").delete()
                completed+=spec.bytes; progress(completed.toDouble()/total)
            }
            validate(staging)
            currentCoroutineContext().ensureActive()
            if (directory.exists() && !directory.deleteRecursively()) problem("model_download_failed")
            if (!staging.renameTo(directory)) problem("model_download_failed")
            File(directory,"verified").writeText(fingerprint)
        }
    }
}

internal class InferenceGate {
    val recording=MutableStateFlow(false)
    private val mutex=Mutex()
    suspend fun <T> run(task: suspend ()->T): T {
        while(true) {
            recording.first { !it }
            mutex.lock()
            try { if(!recording.value) return task() } finally { mutex.unlock() }
        }
    }
}

internal class OfflineSpeech(context: Context, private val gate: InferenceGate) {
    private val languages=listOf("zh-CN","yue-HK","en-US","en-GB","en-NZ","ja-JP","ko-KR")
    private val definition=JSONObject(context.assets.open("dependencies.json").bufferedReader().use { it.readText() }).getJSONObject("asr")
    val store=ModelStore(context,definition.getString("id"),definition.getJSONArray("files").let { files ->
        (0 until files.length()).map { val f=files.getJSONObject(it); ModelFile(f.getString("name"),f.getLong("bytes"),f.getString("sha256"),f.getString("url")) }
    })
    fun supported()=languages
    fun status(language: String): String = when {
        languageCode(language) !in setOf("en","zh","ja","yue","ko") -> "unsupported"
        store.installed() -> "ready"
        else -> "download"
    }
    private fun recognizer(directory: File, language: String): OfflineRecognizer = OfflineRecognizer(config=OfflineRecognizerConfig(
        modelConfig=OfflineModelConfig(senseVoice=OfflineSenseVoiceModelConfig(model=File(directory,"model.int8.onnx").path,
            language=languageCode(language),useInverseTextNormalization=true),tokens=File(directory,"tokens.txt").path,numThreads=4)))
    suspend fun prepare(language: String) {
        if(status(language)=="unsupported") problem("language_unsupported")
        store.prepare { directory -> gate.run { recognizer(directory,language).release() } }
    }
    suspend fun transcribe(file: File, language: String): List<SegmentMessage> {
        if(status(language)=="unsupported") problem("language_unsupported")
        if(!store.installed()) problem("resources_missing")
        val result=mutableListOf<SegmentMessage>()
        withContext(Dispatchers.IO) {
            val vad=Vad(config=VadModelConfig(sileroVadModelConfig=SileroVadModelConfig(
                model=File(store.directory,"silero_vad.onnx").path,minSilenceDuration=0.4f,maxSpeechDuration=20f)))
            try {
                suspend fun drain() {
                    while(!vad.empty()) {
                        currentCoroutineContext().ensureActive()
                        val speech=vad.front(); vad.pop()
                        val text=gate.run {
                            val engine=recognizer(store.directory,language)
                            try {
                                val stream=engine.createStream()
                                try { stream.acceptWaveform(speech.samples,16000); engine.decode(stream); engine.getResult(stream).text.trim() }
                                finally { stream.release() }
                            } finally { engine.release() }
                        }
                        if(text.isNotEmpty()) result.add(SegmentMessage("local-${result.size}",text,
                            speech.start/16000.0,(speech.start+speech.samples.size)/16000.0,null))
                        yield()
                    }
                }
                val window = FloatArray(512)
                var filled = 0
                AudioCodec.decode(file) { samples ->
                    var offset = 0
                    while (offset < samples.size) {
                        val count = minOf(window.size - filled, samples.size - offset)
                        samples.copyInto(window, filled, offset, offset + count)
                        filled += count; offset += count
                        if (filled == window.size) { vad.acceptWaveform(window); filled = 0; drain() }
                    }
                }
                if (filled > 0) { window.fill(0f, filled); vad.acceptWaveform(window) }
                vad.flush(); drain()
            } finally { vad.release() }
        }
        if(result.isEmpty()) problem("no_speech")
        return result
    }
}

internal class LocalTranslation {
    private val models=RemoteModelManager.getInstance()
    private fun code(locale: String): String? = languageCode(locale).takeIf { it!="yue" && it in TranslateLanguage.getAllLanguages() }
    suspend fun status(source: String,target: String): String {
        val from=code(source) ?: return "unsupported"
        val to=code(target) ?: return "unsupported"
        if(from==to) return "installed"
        val installed=models.getDownloadedModels(TranslateRemoteModel::class.java).await().map { it.language }.toSet()
        return if(listOf(from,to).filter { it!="en" }.all { it in installed }) "installed" else "download"
    }
    suspend fun prepare(source: String,target: String) {
        val from=code(source) ?: return
        val to=code(target) ?: return
        if (from == to) return
        val engine=Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(from).setTargetLanguage(to).build())
        try { engine.downloadModelIfNeeded(DownloadConditions.Builder().build()).await() } finally { engine.close() }
    }
    suspend fun translate(text: String,source: String,target: String): String {
        if(languageCode(source)==languageCode(target)) return text
        if(status(source,target)!="installed") problem(if(code(source)==null||code(target)==null) "language_unsupported" else "resources_missing")
        val engine=Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(code(source)!!).setTargetLanguage(code(target)!!).build())
        return try { engine.translate(text).await() } finally { engine.close() }
    }
}
