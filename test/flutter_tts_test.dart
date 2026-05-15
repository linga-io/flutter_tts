import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('platformCallHandler dispatches speak callbacks', () async {
    final flutterTts = FlutterTts();
    var started = false;
    var completed = false;
    var paused = false;
    var continued = false;
    var canceled = false;
    Object? error;

    flutterTts.setStartHandler(() => started = true);
    flutterTts.setCompletionHandler(() => completed = true);
    flutterTts.setPauseHandler(() => paused = true);
    flutterTts.setContinueHandler(() => continued = true);
    flutterTts.setCancelHandler(() => canceled = true);
    flutterTts.setErrorHandler((message) => error = message);

    await flutterTts.platformCallHandler(const MethodCall('speak.onStart'));
    await flutterTts.platformCallHandler(const MethodCall('speak.onComplete'));
    await flutterTts.platformCallHandler(const MethodCall('speak.onPause'));
    await flutterTts.platformCallHandler(const MethodCall('speak.onContinue'));
    await flutterTts.platformCallHandler(const MethodCall('speak.onCancel'));
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onError', 'boom'),
    );

    expect(started, isTrue);
    expect(completed, isTrue);
    expect(paused, isTrue);
    expect(continued, isTrue);
    expect(canceled, isTrue);
    expect(error, 'boom');
  });

  test('platformCallHandler dispatches progress callbacks', () async {
    final flutterTts = FlutterTts();
    String? text;
    int? start;
    int? end;
    String? word;

    flutterTts
        .setProgressHandler((currentText, startOffset, endOffset, currentWord) {
      text = currentText;
      start = startOffset;
      end = endOffset;
      word = currentWord;
    });

    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello world',
        'start': 0,
        'end': 5,
        'word': 'hello',
      }),
    );

    expect(text, 'hello world');
    expect(start, 0);
    expect(end, 5);
    expect(word, 'hello');
  });
}
