import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> sendPlatformCallback(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );
  }

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

  test('rejected speak keeps callbacks on previous active instance', () async {
    const channel = MethodChannel('flutter_tts');
    var speakCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'speak') {
        speakCalls++;
        return speakCalls == 1 ? 1 : 0;
      }
      return 1;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final first = FlutterTts();
    final second = FlutterTts();
    var firstCompleted = false;
    var secondCompleted = false;

    first.setCompletionHandler(() => firstCompleted = true);
    second.setCompletionHandler(() => secondCompleted = true);

    expect(await first.speak('one'), 1);
    expect(await second.speak('two'), 0);

    await sendPlatformCallback(const MethodCall('speak.onComplete'));

    expect(firstCompleted, isTrue);
    expect(secondCompleted, isFalse);
  });

  test('stop does not take callback ownership from active instance', () async {
    const channel = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => 1);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final first = FlutterTts();
    final second = FlutterTts();
    var firstCanceled = false;
    var secondCanceled = false;

    first.setCancelHandler(() => firstCanceled = true);
    second.setCancelHandler(() => secondCanceled = true);

    expect(await first.speak('one'), 1);
    expect(await second.stop(), 1);

    await sendPlatformCallback(const MethodCall('speak.onCancel'));

    expect(firstCanceled, isTrue);
    expect(secondCanceled, isFalse);
  });
}
