package app.capyvibe.phrayo.voice

import com.ibm.icu.text.RuleBasedNumberFormat
import java.io.File
import java.util.Locale

/** Same number/counter preparation and IPADic pronunciation column as iOS. */
class JapaneseSpeechText(private val dictionary: File) {
    fun readings(text: String): String {
        val numbers = RuleBasedNumberFormat(Locale.JAPAN, RuleBasedNumberFormat.SPELLOUT)
        val spelled = Regex("[0-9]+(?:\\.[0-9]+)?").replace(text) { match ->
            val value = match.value.toDoubleOrNull()
            if (value != null && value.isFinite()) numbers.format(value) else match.value
        }
        val people = mapOf("一" to "ひとり", "二" to "ふたり")
        val bottles = mapOf("一" to "いっぽん", "二" to "にほん", "三" to "さんぼん", "四" to "よんほん",
            "五" to "ごほん", "六" to "ろっぽん", "七" to "ななほん", "八" to "はっぽん", "九" to "きゅうほん", "十" to "じゅっぽん")
        val normalized = Regex("[〇零一二三四五六七八九十百千万億兆]+[人本]").replace(spelled) { match ->
            val suffix = spelled.substring(match.range.last + 1)
            val ending = match.value.last()
            val number = match.value.dropLast(1)
            when {
                ending == '人' && listOf("前", "称", "三脚").any { suffix.startsWith(it) } -> match.value
                ending == '本' && suffix.isNotEmpty() && hasKanji(suffix.take(1)) && suffix.first() !in "分目入" -> match.value
                ending == '人' -> people[number] ?: match.value
                else -> bottles[number] ?: match.value
            }
        }
        val raw = NativeVoice.japanese(dictionary.path, normalized.toByteArray(Charsets.UTF_8)).toString(Charsets.UTF_8)
        val reading = raw.map { if (it in '\u3041'..'\u3096') (it.code + 0x60).toChar() else it }.joinToString("")
        check(!hasKanji(reading)) { "Japanese reading is unavailable for this text" }
        return reading
    }

    private fun hasKanji(text: String): Boolean = text.codePoints().anyMatch {
        it in 0x3400..0x4dbf || it in 0x4e00..0x9fff || it in 0x20000..0x3134f || it == 0x3005 || it == 0x3007
    }
}
