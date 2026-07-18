final RegExp _fallbackBoundaryDelimiter = RegExp(
  r'[\s,.!?;:()\[\]{}"“”‘’«»—–…]',
);

/// Resolves the end offset for a browser speech boundary event.
///
/// Browser offsets and Dart string offsets are both UTF-16 code units. Modern
/// engines provide [charLength]; the delimiter scan is only a compatibility
/// fallback for engines that omit it.
int resolveWebSpeechBoundaryEnd(String text, int charIndex, int? charLength) {
  if (charIndex < 0 || charIndex >= text.length) return charIndex;
  if (charLength != null && charLength > 0) {
    final end = charIndex + charLength;
    return end > text.length ? text.length : end;
  }

  var end = charIndex;
  while (end < text.length && !_fallbackBoundaryDelimiter.hasMatch(text[end])) {
    end++;
  }
  return end;
}
