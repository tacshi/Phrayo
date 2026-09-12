/// Shared limits keep the entire vocabulary usable by every supported provider.
List<String> normalizeTranscriptionTerms(Iterable<String> entries) {
  final terms = entries
      .map((term) => term.trim())
      .where((term) => term.isNotEmpty)
      .toSet()
      .toList();
  if (terms.length > 20) throw StateError('vocabulary_too_many');
  if (terms.any((term) => term.runes.length > 30)) {
    throw StateError('vocabulary_too_long');
  }
  return List.unmodifiable(terms);
}
