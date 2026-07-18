import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/src/web_boundary.dart';

void main() {
  test('uses the browser-provided UTF-16 boundary length', () {
    const text = '你好世界';

    expect(resolveWebSpeechBoundaryEnd(text, 0, 2), 2);
  });

  test('keeps emoji boundaries in UTF-16 code units', () {
    const text = '🙂 hello';

    expect(resolveWebSpeechBoundaryEnd(text, 0, 2), 2);
  });

  test('clamps an oversized browser boundary to the text', () {
    expect(resolveWebSpeechBoundaryEnd('hello', 3, 20), 5);
  });

  test('falls back at punctuation omitted by the old scanner', () {
    const text = 'hello; world';

    expect(resolveWebSpeechBoundaryEnd(text, 0, null), 5);
  });
}
