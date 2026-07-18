import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'interop_types.dart';
import 'src/web_boundary.dart';

@JS('String')
external JSString _jsString(JSAny? value);

enum TtsState { playing, stopped, paused, continued }

class FlutterTtsPlugin {
  static const String platformChannel = "flutter_tts";
  static late MethodChannel channel;
  bool awaitSpeakCompletion = false;

  TtsState ttsState = TtsState.stopped;

  bool get isPlaying => ttsState == TtsState.playing;

  bool get isStopped => ttsState == TtsState.stopped;

  bool get isPaused => ttsState == TtsState.paused;

  bool get isContinued => ttsState == TtsState.continued;

  static void registerWith(Registrar registrar) {
    channel = MethodChannel(
      platformChannel,
      const StandardMethodCodec(),
      registrar,
    );
    final instance = FlutterTtsPlugin();
    channel.setMethodCallHandler(instance.handleMethodCall);
  }

  _WebSpeechSession? _activeSession;
  SpeechSynthesisVoice? _selectedVoice;
  String? _selectedLanguage;
  double _rate = 1;
  double _volume = 1;
  double _pitch = 1;
  List<SpeechSynthesisVoice> voices = [];
  List<String> languages = [];
  Timer? _keepAliveTimer;
  Timer? _keepAliveEventResetTimer;
  bool _suppressKeepAlivePause = false;
  bool _suppressKeepAliveResume = false;
  bool supported = false;

  FlutterTtsPlugin() {
    try {
      SpeechSynthesisUtterance();
      _refreshVoices();
      synth.onVoicesChanged = (JSAny e) {
        _refreshVoices();
      }.toJS;
      supported = true;
    } catch (e) {
      print('Initialization of TTS failed. Functions are disabled. Error: $e');
    }
  }

  void _attachListeners(_WebSpeechSession session) {
    final utterance = session.utterance;
    utterance.onStart = (JSAny e) {
      if (!_isActive(session)) return;
      ttsState = TtsState.playing;
      channel.invokeMethod(
        "speak.onStart",
        _eventArguments(session.utteranceId),
      );
      _startKeepAliveIfNeeded(session);
    }.toJS;
    utterance.onEnd = (JSAny e) {
      if (!_isActive(session)) return;
      _finishSession(session, completionValue: 1);
      channel.invokeMethod(
        "speak.onComplete",
        _eventArguments(session.utteranceId),
      );
    }.toJS;

    utterance.onPause = (JSAny e) {
      if (!_isActive(session)) return;
      if (_suppressKeepAlivePause) {
        _suppressKeepAlivePause = false;
        return;
      }
      if (ttsState == TtsState.paused) return;
      ttsState = TtsState.paused;
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      channel.invokeMethod(
        "speak.onPause",
        _eventArguments(session.utteranceId),
      );
    }.toJS;

    utterance.onResume = (JSAny e) {
      if (!_isActive(session)) return;
      if (_suppressKeepAliveResume) {
        _suppressKeepAliveResume = false;
        return;
      }
      if (ttsState == TtsState.continued) return;
      ttsState = TtsState.continued;
      channel.invokeMethod(
        "speak.onContinue",
        _eventArguments(session.utteranceId),
      );
      // An explicit pause may outlive the periodic keepalive timer. Restart it
      // after the browser confirms that speech has resumed.
      _startKeepAliveIfNeeded(session);
    }.toJS;

    utterance.onError = (JSObject event) {
      if (!_isActive(session)) return;
      final errorMessage = _jsString(event["error"] ?? event).toDart;
      _finishSession(session, error: errorMessage);
      channel.invokeMethod(
        "speak.onError",
        _errorArguments(session.utteranceId, errorMessage),
      );
    }.toJS;

    utterance.onBoundary = (JSObject event) {
      if (!_isActive(session)) return;
      final charIndex = (event['charIndex'] as JSNumber?)?.toDartInt;
      final charLength = (event['charLength'] as JSNumber?)?.toDartInt;
      final name = (event['name'] as JSString?)?.toDart;
      if (charIndex == null) return;
      if (name == 'sentence') return;
      final text = session.text;
      if (charIndex < 0 || charIndex >= text.length) return;
      final endIndex = resolveWebSpeechBoundaryEnd(text, charIndex, charLength);
      if (endIndex <= charIndex) return;
      final word = text.substring(charIndex, endIndex);
      final progressArgs = <String, dynamic>{
        'text': text,
        'start': charIndex,
        'end': endIndex,
        'word': word,
        if (session.utteranceId != null) 'utteranceId': session.utteranceId,
      };
      channel.invokeMethod("speak.onProgress", progressArgs);
    }.toJS;
  }

  void _startKeepAliveIfNeeded(_WebSpeechSession session) {
    if (session.utterance.voice?.isLocalService ?? false) return;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 14), (timer) {
      final isActivelySpeaking =
          ttsState == TtsState.playing || ttsState == TtsState.continued;
      if (!_isActive(session) || !isActivelySpeaking) {
        timer.cancel();
        return;
      }
      _suppressKeepAlivePause = true;
      _suppressKeepAliveResume = true;
      synth.pause();
      synth.resume();
      _keepAliveEventResetTimer?.cancel();
      _keepAliveEventResetTimer = Timer(const Duration(seconds: 1), () {
        _suppressKeepAlivePause = false;
        _suppressKeepAliveResume = false;
      });
    });
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    if (!supported) {
      throw PlatformException(
        code: 'Unavailable',
        details: "The browser doesn't support speech synthesis.",
      );
    }
    switch (call.method) {
      case 'speak':
        final request = _speechRequest(call.arguments);
        if (request == null) return 0;
        final activeSession = _activeSession;
        if (isPaused && activeSession != null) {
          if (request.utteranceId != activeSession.utteranceId) return 0;
          // Do not let a delayed keepalive event hide the explicit resume.
          _suppressKeepAliveResume = false;
          synth.resume();
          return 1;
        }
        final session = _startSpeech(request);
        if (session == null) return 0;
        return session.completer?.future ?? 1;
      case 'awaitSpeakCompletion':
        awaitSpeakCompletion = (call.arguments as bool?) ?? false;
        return 1;
      case 'stop':
        _stop();
        return 1;
      case 'pause':
        return _pause() ? 1 : 0;
      case 'setLanguage':
        final language = call.arguments as String;
        return _setLanguage(language) ? 1 : 0;
      case 'getLanguages':
        return _getLanguages();
      case 'getVoices':
        return getVoices();
      case 'setVoice':
        final tmpVoiceMap = Map<String, String>.from(
          call.arguments as LinkedHashMap,
        );
        return _setVoice(tmpVoiceMap) ? 1 : 0;
      case 'setSpeechRate':
        final rate = call.arguments as double;
        _setRate(rate);
        return 1;
      case 'setVolume':
        final volume = call.arguments as double;
        _setVolume(volume);
        return 1;
      case 'setPitch':
        final pitch = call.arguments as double;
        _setPitch(pitch);
        return 1;
      case 'isLanguageAvailable':
        final lang = call.arguments as String;
        return _isLanguageAvailable(lang);
      default:
        throw PlatformException(
          code: 'Unimplemented',
          details: "The flutter_tts plugin for web doesn't implement "
              "the method '${call.method}'",
        );
    }
  }

  _SpeechRequest? _speechRequest(dynamic arguments) {
    if (arguments is String) {
      return arguments.isEmpty ? null : _SpeechRequest(arguments, null);
    }
    if (arguments is Map) {
      final text = arguments['text'];
      final utteranceId = arguments['utteranceId'];
      if (text is String &&
          text.isNotEmpty &&
          (utteranceId == null ||
              (utteranceId is String && utteranceId.isNotEmpty))) {
        return _SpeechRequest(text, utteranceId as String?);
      }
    }
    return null;
  }

  _WebSpeechSession? _startSpeech(_SpeechRequest request) {
    // Do not rely on onStart to mark the operation active. Browsers dispatch
    // it asynchronously, so a second immediate speak must already be rejected.
    if (_activeSession != null) return null;

    final utterance = SpeechSynthesisUtterance()
      ..text = request.text
      ..rate = _rate
      ..volume = _volume
      ..pitch = _pitch;
    final voice = _selectedVoice;
    if (voice != null) utterance.voice = voice;
    final language = _selectedLanguage;
    if (language != null) utterance.lang = language;
    final session = _WebSpeechSession(
      utterance,
      request.text,
      request.utteranceId,
      awaitSpeakCompletion ? Completer<dynamic>() : null,
    );
    _activeSession = session;
    _attachListeners(session);
    try {
      synth.speak(utterance);
    } catch (_) {
      _finishSession(session);
      rethrow;
    }
    return session;
  }

  void _stop() {
    final session = _activeSession;
    if (session != null) {
      // onStart may not have fired yet, but the utterance is already queued.
      _finishSession(session, completionValue: 0);
      synth.cancel();
      channel.invokeMethod(
        'speak.onCancel',
        _eventArguments(session.utteranceId),
      );
    }
  }

  bool _pause() {
    if (_activeSession == null) return false;
    if (ttsState == TtsState.paused) return true;
    // A browser may omit one half of the keepalive pause/resume event pair.
    // Ensure the next pause event still represents this explicit request.
    _suppressKeepAlivePause = false;
    synth.pause();
    return true;
  }

  bool _isActive(_WebSpeechSession session) =>
      identical(_activeSession, session);

  void _finishSession(
    _WebSpeechSession session, {
    Object? error,
    dynamic completionValue,
  }) {
    if (!_isActive(session)) return;
    _activeSession = null;
    ttsState = TtsState.stopped;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _keepAliveEventResetTimer?.cancel();
    _keepAliveEventResetTimer = null;
    _suppressKeepAlivePause = false;
    _suppressKeepAliveResume = false;
    final completer = session.completer;
    if (completer != null && !completer.isCompleted) {
      if (session.utteranceId != null) {
        completer.complete(<String, dynamic>{
          'accepted': true,
          'value': error == null ? completionValue : 0,
        });
      } else if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(completionValue);
      }
    }
  }

  dynamic _eventArguments(String? utteranceId) => utteranceId == null
      ? null
      : <String, dynamic>{'utteranceId': utteranceId};

  dynamic _errorArguments(String? utteranceId, String message) =>
      utteranceId == null
          ? message
          : <String, dynamic>{'utteranceId': utteranceId, 'message': message};

  void _setRate(double rate) => _rate = rate;
  void _setVolume(double volume) => _volume = volume;
  void _setPitch(double pitch) => _pitch = pitch;
  bool _setLanguage(String language) {
    var targetList = voices.where((e) {
      return _languageMatches(language, e.lang);
    });
    if (targetList.isNotEmpty) {
      _selectedVoice = targetList.first;
      _selectedLanguage = targetList.first.lang;
      return true;
    }
    return false;
  }

  bool _setVoice(Map<String?, String?> voice) {
    var targetList = voices.where((e) {
      return voice["name"] == e.name && voice["locale"] == e.lang;
    });
    if (targetList.isNotEmpty) {
      _selectedVoice = targetList.first;
      _selectedLanguage = targetList.first.lang;
      return true;
    }
    return false;
  }

  bool _isLanguageAvailable(String? language) {
    if (language == null || language.isEmpty) return false;
    if (voices.isEmpty) _setVoices();
    if (languages.isEmpty) _setLanguages();
    for (var lang in languages) {
      if (_languageMatches(language, lang)) return true;
    }
    return false;
  }

  bool _languageMatches(String requested, String candidate) {
    final normalizedRequested = requested.replaceAll('_', '-').toLowerCase();
    final normalizedCandidate = candidate.replaceAll('_', '-').toLowerCase();
    if (normalizedCandidate == normalizedRequested) return true;
    return !normalizedRequested.contains('-') &&
        normalizedCandidate.split('-').first == normalizedRequested;
  }

  List<String?>? _getLanguages() {
    if (voices.isEmpty) _setVoices();
    if (languages.isEmpty) _setLanguages();
    return languages;
  }

  void _refreshVoices() {
    voices = synth.getVoices().toDart;
    _setLanguages();
  }

  void _setVoices() {
    _refreshVoices();
  }

  Future<List<Map<String, String>>> getVoices() async {
    var tmpVoices = synth.getVoices().toDart;
    return tmpVoices
        .map((voice) => {"name": voice.name, "locale": voice.lang})
        .toList();
  }

  void _setLanguages() {
    var langs = <String>{};
    for (var v in voices) {
      langs.add(v.lang);
    }

    languages = langs.toList();
  }
}

class _SpeechRequest {
  final String text;
  final String? utteranceId;

  const _SpeechRequest(this.text, this.utteranceId);
}

class _WebSpeechSession {
  final SpeechSynthesisUtterance utterance;
  final String text;
  final String? utteranceId;
  final Completer<dynamic>? completer;

  const _WebSpeechSession(
    this.utterance,
    this.text,
    this.utteranceId,
    this.completer,
  );
}
