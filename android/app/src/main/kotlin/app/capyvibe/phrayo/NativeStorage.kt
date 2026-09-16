package app.capyvibe.phrayo

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal fun problem(code: String): Nothing = throw FlutterError(code, code, null)
internal fun languageCode(value: String): String {
    val code = value.replace('_', '-').lowercase()
    return if (code == "yue" || code.startsWith("yue-") || code == "zh-hk" || code == "zh-hant-hk") "yue" else code.substringBefore('-')
}
internal fun vocabulary(terms: List<String>): List<String> {
    val values = terms.map(String::trim).filter(String::isNotEmpty).distinct()
    if (values.size > 20) problem("vocabulary_too_many")
    if (values.any { it.codePointCount(0, it.length) > 30 }) problem("vocabulary_too_long")
    return values
}
internal fun writeJson(file: File, value: JSONObject) {
    file.parentFile!!.mkdirs()
    val atomic = AtomicFile(file)
    val output = atomic.startWrite()
    try { output.write(value.toString().toByteArray()); atomic.finishWrite(output) }
    catch (error: Throwable) { atomic.failWrite(output); throw error }
}
internal fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else getString(key)
internal fun SessionMessage.json(): JSONObject = JSONObject().put("id", id).put("kind", kind).put("state", state)
    .put("seconds", seconds).put("level", level).put("transcript", transcript).put("translation", translation)
    .put("path", path ?: JSONObject.NULL).put("error", error ?: JSONObject.NULL)
    .put("sourceLanguage", sourceLanguage ?: JSONObject.NULL).put("targetLanguage", targetLanguage ?: JSONObject.NULL)
    .put("sttJobJson", sttJobJson ?: JSONObject.NULL).put("segments", JSONArray(segments.map {
        JSONObject().put("id", it.id).put("text", it.text).put("start", it.start).put("end", it.end).put("speaker", it.speaker ?: JSONObject.NULL)
    }))
internal fun sessionFromJson(json: JSONObject): SessionMessage {
    val rows = json.optJSONArray("segments") ?: JSONArray()
    return SessionMessage(id=json.getString("id"), kind=json.getString("kind"), state=json.getString("state"),
        seconds=json.getDouble("seconds"), level=json.optDouble("level", 0.0), transcript=json.optString("transcript"),
        translation=json.optString("translation"), path=json.stringOrNull("path"), error=json.stringOrNull("error"),
        sourceLanguage=json.stringOrNull("sourceLanguage"), targetLanguage=json.stringOrNull("targetLanguage"),
        sttJobJson=json.stringOrNull("sttJobJson"), segments=(0 until rows.length()).map { index ->
            val row=rows.getJSONObject(index)
            SegmentMessage(row.getString("id"),row.getString("text"),row.getDouble("start"),row.getDouble("end"),row.stringOrNull("speaker"))
        })
}

internal class AudioFiles(context: Context) {
    val root = File(context.filesDir, "Audio").apply { mkdirs() }.canonicalFile
    fun folder(id: String): File {
        if (runCatching { UUID.fromString(id).toString().equals(id, true) }.getOrDefault(false).not()) problem("invalid_audio_path")
        val file=File(root,id)
        if (file.canonicalFile != file.absoluteFile) problem("invalid_audio_path")
        return file
    }
    fun audio(path: String): File {
        val file=if (File(path).isAbsolute) File(path) else File(root,path)
        val id=file.parentFile?.name ?: problem("invalid_audio_path")
        val expected=File(folder(id),"recording.m4a")
        if (file.name!="recording.m4a" || file.absoluteFile!=expected.absoluteFile || file.canonicalFile!=expected.absoluteFile) problem("invalid_audio_path")
        return expected
    }
    fun save(session: SessionMessage) = writeJson(File(folder(session.id),"session.json"),session.json())
    fun acknowledge(id: String) { File(folder(id),"session.json").delete() }
    fun recover(): List<SessionMessage> = root.listFiles().orEmpty().filter { it.isDirectory }.mapNotNull { directory ->
        runCatching {
            val file=File(folder(directory.name),"session.json")
            if (!file.exists()) return@mapNotNull null
            val saved=sessionFromJson(JSONObject(file.readText()))
            if (saved.id != directory.name) return@mapNotNull null
            if (saved.state in listOf("recording","paused","processing")) saved.copy(state="interrupted",level=0.0,
                path="${saved.id}/recording.m4a",error="audio_interrupted") else saved
        }.getOrNull()
    }
}

internal class SecretStore(context: Context) {
    private val preferences=context.getSharedPreferences("credentials",Context.MODE_PRIVATE)
    private val alias="app.capyvibe.phrayo.credentials"
    private fun key(): SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias,null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    @Synchronized fun read(service: String): String? {
        val encoded=preferences.getString(service,null) ?: return null
        return try {
            val bytes=Base64.decode(encoded,Base64.NO_WRAP)
            val cipher=Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,bytes.copyOfRange(0,12)))
            cipher.updateAAD(service.toByteArray())
            cipher.doFinal(bytes.copyOfRange(12,bytes.size)).toString(Charsets.UTF_8)
        } catch (_: Exception) { problem("credential_unavailable") }
    }
    @Synchronized fun save(service: String, value: String) {
        require(service in setOf("llm","soniox","moss"))
        if (value.isEmpty()) { preferences.edit().remove(service).commit(); return }
        val cipher=Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE,key()); cipher.updateAAD(service.toByteArray())
        val encoded=Base64.encodeToString(cipher.iv+cipher.doFinal(value.toByteArray()),Base64.NO_WRAP)
        if (!preferences.edit().putString(service,encoded).commit()) problem("credential_unavailable")
    }
}
