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

    flutterTts.setProgressHandler((
      currentText,
      startOffset,
      endOffset,
      currentWord,
    ) {
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

  test('platformCallHandler dispatches utterance-aware callbacks', () async {
    final flutterTts = FlutterTts();
    final events = <String>[];
    Object? legacyError;
    Object? utteranceError;
    String? progressWord;

    flutterTts.setUtteranceStartHandler(
      (utteranceId) => events.add('start:$utteranceId'),
    );
    flutterTts.setUtteranceCompletionHandler(
      (utteranceId) => events.add('complete:$utteranceId'),
    );
    flutterTts.setUtterancePauseHandler(
      (utteranceId) => events.add('pause:$utteranceId'),
    );
    flutterTts.setUtteranceContinueHandler(
      (utteranceId) => events.add('continue:$utteranceId'),
    );
    flutterTts.setUtteranceCancelHandler(
      (utteranceId) => events.add('cancel:$utteranceId'),
    );
    flutterTts.setErrorHandler((message) => legacyError = message);
    flutterTts.setUtteranceErrorHandler((utteranceId, message) {
      events.add('error:$utteranceId');
      utteranceError = message;
    });
    flutterTts.setUtteranceProgressHandler((
      utteranceId,
      text,
      start,
      end,
      word,
    ) {
      events.add('progress:$utteranceId:$start:$end');
      progressWord = word;
    });

    const id = 'chapter-4-sentence-2';
    const token = {'utteranceId': id};
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onStart', token),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        ...token,
        'text': 'hello world',
        'start': 0,
        'end': 5,
        'word': 'hello',
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onPause', token),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onContinue', token),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onCancel', token),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onError', {...token, 'message': 'boom'}),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onComplete', token),
    );

    expect(events, [
      'start:$id',
      'progress:$id:0:5',
      'pause:$id',
      'continue:$id',
      'cancel:$id',
      'error:$id',
      'complete:$id',
    ]);
    expect(progressWord, 'hello');
    expect(legacyError, 'boom');
    expect(utteranceError, 'boom');
  });

  test('malformed progress callbacks are ignored', () async {
    final flutterTts = FlutterTts();
    var calls = 0;
    flutterTts.setProgressHandler((text, start, end, word) => calls++);

    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', 'not-a-map'),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello',
        'start': 'invalid',
        'end': 5,
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello',
        'start': -1,
        'end': 2,
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello',
        'start': 4,
        'end': 2,
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello',
        'start': 2,
        'end': 2,
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello',
        'start': 0,
        'end': 20,
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': '🙂',
        'start': 0,
        'end': 1,
      }),
    );
    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': '🙂',
        'start': 1,
        'end': 2,
      }),
    );

    expect(calls, 0);
  });

  test('progress validation uses Dart UTF-16 offsets', () async {
    final flutterTts = FlutterTts();
    String? word;
    flutterTts.setProgressHandler(
      (text, start, end, currentWord) => word = currentWord,
    );

    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': '🙂 hello',
        'start': 0,
        'end': 2,
        'word': '🙂',
      }),
    );

    expect(word, '🙂');
  });

  test('progress derives a missing word from validated offsets', () async {
    final flutterTts = FlutterTts();
    String? word;
    flutterTts.setProgressHandler(
      (text, start, end, currentWord) => word = currentWord,
    );

    await flutterTts.platformCallHandler(
      const MethodCall('speak.onProgress', {
        'text': 'hello world',
        'start': 6,
        'end': 11,
      }),
    );

    expect(word, 'world');
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

  test('throwing speak keeps callbacks on previous active instance', () async {
    const channel = MethodChannel('flutter_tts');
    var speakCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'speak') {
        speakCalls++;
        if (speakCalls == 2) {
          throw PlatformException(code: 'speak-failed');
        }
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
    await expectLater(second.speak('two'), throwsA(isA<PlatformException>()));
    await sendPlatformCallback(const MethodCall('speak.onComplete'));

    expect(firstCompleted, isTrue);
    expect(secondCompleted, isFalse);
  });

  test('utterance callbacks route to their owning instance', () async {
    const channel = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => 1);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final first = FlutterTts();
    final second = FlutterTts();
    var firstCompleted = 0;
    var secondCompleted = 0;
    first.setUtteranceCompletionHandler((_) => firstCompleted++);
    second.setUtteranceCompletionHandler((_) => secondCompleted++);

    expect(await first.speak('one', utteranceId: 'first-token'), 1);
    expect(await second.speak('two'), 1);
    await sendPlatformCallback(
      const MethodCall('speak.onComplete', {'utteranceId': 'first-token'}),
    );
    // A duplicate terminal callback for an already released token is stale and
    // must not fall back to whichever instance happens to be active.
    await sendPlatformCallback(
      const MethodCall('speak.onComplete', {'utteranceId': 'first-token'}),
    );

    expect(firstCompleted, 1);
    expect(secondCompleted, 0);
  });

  test(
    'unknown tagged callbacks never fall back to the active instance',
    () async {
      const channel = MethodChannel('flutter_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 1);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final flutterTts = FlutterTts();
      var legacyStarts = 0;
      var taggedStarts = 0;
      var progressEvents = 0;
      flutterTts.setStartHandler(() => legacyStarts++);
      flutterTts.setUtteranceStartHandler((_) => taggedStarts++);
      flutterTts.setProgressHandler(
        (text, start, end, word) => progressEvents++,
      );

      expect(await flutterTts.speak('active legacy request'), 1);
      await sendPlatformCallback(
        const MethodCall('speak.onStart', {'utteranceId': 'unknown-token'}),
      );
      await sendPlatformCallback(
        const MethodCall('speak.onProgress', {
          'utteranceId': 'unknown-token',
          'text': 'stale request',
          'start': 0,
          'end': 5,
          'word': 'stale',
        }),
      );

      expect(legacyStarts, 0);
      expect(taggedStarts, 0);
      expect(progressEvents, 0);

      await sendPlatformCallback(const MethodCall('speak.onStart'));
      expect(legacyStarts, 1);
    },
  );

  test('rejected same-token resume preserves existing ownership', () async {
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

    final flutterTts = FlutterTts();
    var completions = 0;
    flutterTts.setUtteranceCompletionHandler((_) => completions++);
    expect(await flutterTts.speak('one', utteranceId: 'resume-token'), 1);
    expect(await flutterTts.speak('one', utteranceId: 'resume-token'), 0);

    await sendPlatformCallback(
      const MethodCall('speak.onComplete', {'utteranceId': 'resume-token'}),
    );
    expect(completions, 1);
  });

  test('throwing same-token resume preserves existing ownership', () async {
    const channel = MethodChannel('flutter_tts');
    var speakCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'speak') {
        speakCalls++;
        if (speakCalls > 1) {
          throw PlatformException(code: 'resume-failed');
        }
      }
      return 1;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final flutterTts = FlutterTts();
    var completions = 0;
    flutterTts.setUtteranceCompletionHandler((_) => completions++);
    expect(await flutterTts.speak('one', utteranceId: 'throwing-resume'), 1);
    await expectLater(
      flutterTts.speak('one', utteranceId: 'throwing-resume'),
      throwsA(isA<PlatformException>()),
    );

    await sendPlatformCallback(
      const MethodCall('speak.onComplete', {'utteranceId': 'throwing-resume'}),
    );
    expect(completions, 1);
  });

  test(
    'accepted awaited cancellation preserves ownership until callback',
    () async {
      const channel = MethodChannel('flutter_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'speak') {
          return <String, dynamic>{'accepted': true, 'value': 0};
        }
        return 1;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final flutterTts = FlutterTts();
      var cancellations = 0;
      flutterTts.setUtteranceCancelHandler((_) => cancellations++);

      expect(await flutterTts.speak('one', utteranceId: 'awaited-cancel'), 0);
      await sendPlatformCallback(
        const MethodCall('speak.onCancel', {'utteranceId': 'awaited-cancel'}),
      );

      expect(cancellations, 1);
    },
  );

  test('speak forwards and validates an utterance identifier', () async {
    const channel = MethodChannel('flutter_tts');
    MethodCall? speakCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'speak') {
        speakCall = call;
      }
      return 1;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final flutterTts = FlutterTts();
    expect(await flutterTts.speak('hello', utteranceId: 'unique-token'), 1);
    expect(speakCall?.arguments, {
      'text': 'hello',
      'utteranceId': 'unique-token',
    });
    await expectLater(
      flutterTts.speak('hello', utteranceId: ''),
      throwsArgumentError,
    );
    speakCall = null;
    expect(await flutterTts.speak('', utteranceId: 'empty-text'), 0);
    expect(speakCall, isNull);

    await sendPlatformCallback(
      const MethodCall('speak.onCancel', {'utteranceId': 'unique-token'}),
    );
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

  test('dispose releases callback ownership and handlers', () async {
    const channel = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => 1);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final flutterTts = FlutterTts();
    var completions = 0;
    flutterTts.setCompletionHandler(() => completions++);
    flutterTts.setUtteranceCompletionHandler((_) => completions++);
    expect(await flutterTts.speak('one', utteranceId: 'disposed-token'), 1);

    flutterTts.dispose();
    await sendPlatformCallback(
      const MethodCall('speak.onComplete', {'utteranceId': 'disposed-token'}),
    );
    await flutterTts.platformCallHandler(const MethodCall('speak.onComplete'));

    expect(completions, 0);
  });
}
