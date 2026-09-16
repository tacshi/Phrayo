package app.capyvibe.phrayo

import java.text.BreakIterator
import java.util.Locale

internal object VoiceTextSegments {
    fun split(text: String, language: String): List<String> {
        val trimmed = text.trim()
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT).apply { setText(trimmed) }
        val characters = mutableListOf<String>()
        var previous = iterator.first()
        var boundary = iterator.next()
        while (boundary != BreakIterator.DONE) {
            characters.add(trimmed.substring(previous, boundary)); previous = boundary; boundary = iterator.next()
        }
        val maximum = if (languageCode(language) in setOf("zh", "yue")) 32 else 96
        val punctuation = "。！？!?；;，,、\n"
        val parts = mutableListOf<String>()
        var start = 0
        while (start < characters.size) {
            var end = (start + maximum).coerceAtMost(characters.size)
            if (end < characters.size) {
                val stop = (start until end).lastOrNull { characters[it].length == 1 && punctuation.contains(characters[it]) }
                    ?: (start + maximum / 2 until end).lastOrNull { characters[it].isBlank() }
                if (stop != null) end = stop + 1
            }
            characters.subList(start, end).joinToString("").trim().takeIf { it.isNotEmpty() }?.let(parts::add)
            start = end
        }
        return parts
    }
}
