import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

typedef ErrorHandler = void Function(dynamic message);
typedef ProgressHandler = void Function(
    String text, int start, int end, String word);

/// Receives a speech lifecycle event and its caller-supplied utterance ID.
///
/// The value is `null` for speech submitted through the legacy tokenless API.
typedef UtteranceHandler = void Function(String? utteranceId);

/// Receives a speech error correlated with its caller-supplied utterance ID.
typedef UtteranceErrorHandler = void Function(
    String? utteranceId, dynamic message);

/// Receives a validated speech range correlated with an utterance ID.
///
/// [start] and [end] are UTF-16 code-unit offsets and can be passed directly
/// to [String.substring].
typedef UtteranceProgressHandler = void Function(
  String? utteranceId,
  String text,
  int start,
  int end,
  String word,
);

const String iosAudioCategoryOptionsKey = 'iosAudioCategoryOptionsKey';
const String iosAudioCategoryKey = 'iosAudioCategoryKey';
const String iosAudioModeKey = 'iosAudioModeKey';
const String iosAudioCategoryAmbientSolo = 'iosAudioCategoryAmbientSolo';
const String iosAudioCategoryAmbient = 'iosAudioCategoryAmbient';
const String iosAudioCategoryPlayback = 'iosAudioCategoryPlayback';
const String iosAudioCategoryPlaybackAndRecord =
    'iosAudioCategoryPlaybackAndRecord';

const String iosAudioCategoryOptionsMixWithOthers =
    'iosAudioCategoryOptionsMixWithOthers';
const String iosAudioCategoryOptionsDuckOthers =
    'iosAudioCategoryOptionsDuckOthers';
const String iosAudioCategoryOptionsInterruptSpokenAudioAndMixWithOthers =
    'iosAudioCategoryOptionsInterruptSpokenAudioAndMixWithOthers';
const String iosAudioCategoryOptionsAllowBluetooth =
    'iosAudioCategoryOptionsAllowBluetooth';
const String iosAudioCategoryOptionsAllowBluetoothA2DP =
    'iosAudioCategoryOptionsAllowBluetoothA2DP';
const String iosAudioCategoryOptionsAllowAirPlay =
    'iosAudioCategoryOptionsAllowAirPlay';
const String iosAudioCategoryOptionsDefaultToSpeaker =
    'iosAudioCategoryOptionsDefaultToSpeaker';

const String iosAudioModeDefault = 'iosAudioModeDefault';
const String iosAudioModeGameChat = 'iosAudioModeGameChat';
const String iosAudioModeMeasurement = 'iosAudioModeMeasurement';
const String iosAudioModeMoviePlayback = 'iosAudioModeMoviePlayback';
const String iosAudioModeSpokenAudio = 'iosAudioModeSpokenAudio';
const String iosAudioModeVideoChat = 'iosAudioModeVideoChat';
const String iosAudioModeVideoRecording = 'iosAudioModeVideoRecording';
const String iosAudioModeVoiceChat = 'iosAudioModeVoiceChat';
const String iosAudioModeVoicePrompt = 'iosAudioModeVoicePrompt';

enum TextToSpeechPlatform { android, ios, macos }

/// Audio session category identifiers for iOS.
///
/// See also:
/// * https://developer.apple.com/documentation/avfaudio/avaudiosession/category
enum IosTextToSpeechAudioCategory {
  /// The default audio session category.
  ///
  /// Your audio is silenced by screen locking and by the Silent switch.
  ///
  /// By default, using this category implies that your app’s audio
  /// is nonmixable—activating your session will interrupt
  /// any other audio sessions which are also nonmixable.
  /// To allow mixing, use the [ambient] category instead.
  ambientSolo,

  /// The category for an app in which sound playback is nonprimary — that is,
  /// your app also works with the sound turned off.
  ///
  /// This category is also appropriate for “play-along” apps,
  /// such as a virtual piano that a user plays while the Music app is playing.
  /// When you use this category, audio from other apps mixes with your audio.
  /// Screen locking and the Silent switch (on iPhone, the Ring/Silent switch) silence your audio.
  ambient,

  /// The category for playing recorded music or other sounds
  /// that are central to the successful use of your app.
  ///
  /// When using this category, your app audio continues
  /// with the Silent switch set to silent or when the screen locks.
  ///
  /// By default, using this category implies that your app’s audio
  /// is nonmixable—activating your session will interrupt
  /// any other audio sessions which are also nonmixable.
  /// To allow mixing for this category, use the
  /// [IosTextToSpeechAudioCategoryOptions.mixWithOthers] option.
  playback,

  /// The category for recording (input) and playback (output) of audio,
  /// such as for a Voice over Internet Protocol (VoIP) app.
  ///
  /// Your audio continues with the Silent switch set to silent and with the screen locked.
  /// This category is appropriate for simultaneous recording and playback,
  /// and also for apps that record and play back, but not simultaneously.
  playAndRecord,
}

/// Audio session mode identifiers for iOS.
///
/// See also:
/// * https://developer.apple.com/documentation/avfaudio/avaudiosession/mode
enum IosTextToSpeechAudioMode {
  /// The default audio session mode.
  ///
  /// You can use this mode with every [IosTextToSpeechAudioCategory].
  defaultMode,

  /// A mode that the GameKit framework sets on behalf of an application
  /// that uses GameKit’s voice chat service.
  ///
  /// This mode is valid only with the
  /// [IosTextToSpeechAudioCategory.playAndRecord] category.
  ///
  /// Don’t set this mode directly. If you need similar behavior and aren’t
  /// using a `GKVoiceChat` object, use [voiceChat] or [videoChat] instead.
  gameChat,

  /// A mode that indicates that your app is performing measurement of audio input or output.
  ///
  /// Use this mode for apps that need to minimize the amount of
  /// system-supplied signal processing to input and output signals.
  /// If recording on devices with more than one built-in microphone,
  /// the session uses the primary microphone.
  ///
  /// For use with the [IosTextToSpeechAudioCategory.playback] or
  /// [IosTextToSpeechAudioCategory.playAndRecord] category.
  ///
  /// **Important:** This mode disables some dynamics processing on input and output signals,
  /// resulting in a lower-output playback level.
  measurement,

  /// A mode that indicates that your app is playing back movie content.
  ///
  /// When you set this mode, the audio session uses signal processing to enhance
  /// movie playback for certain audio routes such as built-in speaker or headphones.
  /// You may only use this mode with the
  /// [IosTextToSpeechAudioCategory.playback] category.
  moviePlayback,

  /// A mode used for continuous spoken audio to pause the audio when another app plays a short audio prompt.
  ///
  /// This mode is appropriate for apps that play continuous spoken audio,
  /// such as podcasts or audio books. Setting this mode indicates that your app
  /// should pause, rather than duck, its audio if another app plays
  /// a spoken audio prompt. After the interrupting app’s audio ends, you can
  /// resume your app’s audio playback.
  spokenAudio,

  /// A mode that indicates that your app is engaging in online video conferencing.
  ///
  /// Use this mode for video chat apps that use the
  /// [IosTextToSpeechAudioCategory.playAndRecord] category.
  /// When you set this mode, the audio session optimizes the device’s tonal
  /// equalization for voice. It also reduces the set of allowable audio routes
  /// to only those appropriate for video chat.
  ///
  /// Using this mode has the side effect of enabling the
  /// [IosTextToSpeechAudioCategoryOptions.allowBluetooth] category option.
  videoChat,

  /// A mode that indicates that your app is recording a movie.
  ///
  /// This mode is valid only with the
  /// [IosTextToSpeechAudioCategory.playAndRecord] category.
  /// On devices with more than one built-in microphone,
  /// the audio session uses the microphone closest to the video camera.
  ///
  /// Use this mode to ensure that the system provides appropriate audio-signal processing.
  videoRecording,

  /// A mode that indicates that your app is performing two-way voice communication,
  /// such as using Voice over Internet Protocol (VoIP).
  ///
  /// Use this mode for Voice over IP (VoIP) apps that use the
  /// [IosTextToSpeechAudioCategory.playAndRecord] category.
  /// When you set this mode, the session optimizes the device’s tonal
  /// equalization for voice and reduces the set of allowable audio routes
  /// to only those appropriate for voice chat.
  ///
  /// Using this mode has the side effect of enabling the
  /// [IosTextToSpeechAudioCategoryOptions.allowBluetooth] category option.
  voiceChat,

  /// A mode that indicates that your app plays audio using text-to-speech.
  ///
  /// Setting this mode allows for different routing behaviors when your app
  /// is connected to certain audio devices, such as CarPlay.
  /// An example of an app that uses this mode is a turn-by-turn navigation app
  /// that plays short prompts to the user.
  ///
  /// Typically, apps of the same type also configure their sessions to use the
  /// [IosTextToSpeechAudioCategoryOptions.duckOthers] and
  /// [IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers] options.
  voicePrompt,
}

/// Audio session category options for iOS.
///
/// See also:
/// * https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions
enum IosTextToSpeechAudioCategoryOptions {
  /// An option that indicates whether audio from this session mixes with audio
  /// from active sessions in other audio apps.
  ///
  /// You can set this option explicitly only if the audio session category
  /// is [IosTextToSpeechAudioCategory.playAndRecord] or
  /// [IosTextToSpeechAudioCategory.playback].
  /// If you set the audio session category to [IosTextToSpeechAudioCategory.ambient],
  /// the session automatically sets this option.
  /// Likewise, setting the [duckOthers] or [interruptSpokenAudioAndMixWithOthers]
  /// options also enables this option.
  ///
  /// If you set this option, your app mixes its audio with audio playing
  /// in background apps, such as the Music app.
  mixWithOthers,

  /// An option that reduces the volume of other audio sessions while audio
  /// from this session plays.
  ///
  /// You can set this option only if the audio session category is
  /// [IosTextToSpeechAudioCategory.playAndRecord] or
  /// [IosTextToSpeechAudioCategory.playback].
  /// Setting it implicitly sets the [mixWithOthers] option.
  ///
  /// Use this option to mix your app’s audio with that of others.
  /// While your app plays its audio, the system reduces the volume of other
  /// audio sessions to make yours more prominent. If your app provides
  /// occasional spoken audio, such as in a turn-by-turn navigation app
  /// or an exercise app, you should also set the [interruptSpokenAudioAndMixWithOthers] option.
  ///
  /// Note that ducking begins when you activate your app’s audio session
  /// and ends when you deactivate the session.
  ///
  /// See also:
  /// * [FlutterTts.setSharedInstance]
  duckOthers,

  /// An option that determines whether to pause spoken audio content
  /// from other sessions when your app plays its audio.
  ///
  /// You can set this option only if the audio session category is
  /// [IosTextToSpeechAudioCategory.playAndRecord] or
  /// [IosTextToSpeechAudioCategory.playback].
  /// Setting this option also sets [mixWithOthers].
  ///
  /// If you set this option, the system mixes your audio with other
  /// audio sessions, but interrupts (and stops) audio sessions that use the
  /// [IosTextToSpeechAudioMode.spokenAudio] audio session mode.
  /// It pauses the audio from other apps as long as your session is active.
  /// After your audio session deactivates, the system resumes the interrupted app’s audio.
  ///
  /// Set this option if your app’s audio is occasional and spoken,
  /// such as in a turn-by-turn navigation app or an exercise app.
  /// This avoids intelligibility problems when two spoken audio apps mix.
  /// If you set this option, also set the [duckOthers] option unless
  /// you have a specific reason not to. Ducking other audio, rather than
  /// interrupting it, is appropriate when the other audio isn’t spoken audio.
  interruptSpokenAudioAndMixWithOthers,

  /// An option that determines whether Bluetooth hands-free devices appear
  /// as available input routes.
  ///
  /// You can set this option only if the audio session category is
  /// [IosTextToSpeechAudioCategory.playAndRecord] or
  /// [IosTextToSpeechAudioCategory.playback].
  ///
  /// You’re required to set this option to allow routing audio input and output
  /// to a paired Bluetooth Hands-Free Profile (HFP) device.
  /// If you clear this option, paired Bluetooth HFP devices don’t show up
  /// as available audio input routes.
  allowBluetooth,

  /// An option that determines whether you can stream audio from this session
  /// to Bluetooth devices that support the Advanced Audio Distribution Profile (A2DP).
  ///
  /// A2DP is a stereo, output-only profile intended for higher bandwidth
  /// audio use cases, such as music playback.
  /// The system automatically routes to A2DP ports if you configure an
  /// app’s audio session to use the [IosTextToSpeechAudioCategory.ambient],
  /// [IosTextToSpeechAudioCategory.ambientSolo], or
  /// [IosTextToSpeechAudioCategory.playback] categories.
  ///
  /// Starting with iOS 10.0, apps using the
  /// [IosTextToSpeechAudioCategory.playAndRecord] category may also allow
  /// routing output to paired Bluetooth A2DP devices. To enable this behavior,
  /// pass this category option when setting your audio session’s category.
  ///
  /// Note: If this option and the [allowBluetooth] option are both set,
  /// when a single device supports both the Hands-Free Profile (HFP) and A2DP,
  /// the system gives hands-free ports a higher priority for routing.
  allowBluetoothA2DP,

  /// An option that determines whether you can stream audio
  /// from this session to AirPlay devices.
  ///
  /// Setting this option enables the audio session to route audio output
  /// to AirPlay devices. You can only explicitly set this option if the
  /// audio session’s category is set to [IosTextToSpeechAudioCategory.playAndRecord].
  /// For most other audio session categories, the system sets this option implicitly.
  allowAirPlay,

  /// An option that determines whether audio from the session defaults to the built-in speaker instead of the receiver.
  ///
  /// You can set this option only when using the
  /// [IosTextToSpeechAudioCategory.playAndRecord] category.
  /// It’s used to modify the category’s routing behavior so that audio
  /// is always routed to the speaker rather than the receiver if
  /// no other accessories, such as headphones, are in use.
  ///
  /// When using this option, the system honors user gestures.
  /// For example, plugging in a headset causes the route to change to
  /// headset mic/headphones, and unplugging the headset causes the route
  /// to change to built-in mic/speaker (as opposed to built-in mic/receiver)
  /// when you’ve set this override.
  ///
  /// In the case of using a USB input-only accessory, audio input
  /// comes from the accessory, and the system routes audio to the headphones,
  /// if attached, or to the speaker if the headphones aren’t plugged in.
  /// The use case is to route audio to the speaker instead of the receiver
  /// in cases where the audio would normally go to the receiver.
  defaultToSpeaker,
}

/// Platform-specific normalized speech-rate limits.
class SpeechRateValidRange {
  /// Slowest accepted normalized rate.
  final double min;

  /// Platform's normal speaking rate.
  final double normal;

  /// Fastest accepted normalized rate.
  final double max;

  /// Platform that reported these limits.
  final TextToSpeechPlatform platform;

  /// Creates an immutable platform speech-rate range.
  const SpeechRateValidRange(this.min, this.normal, this.max, this.platform);
}

/// Provides platform text-to-speech services through Flutter method channels.
class FlutterTts {
  static const MethodChannel _channel = MethodChannel('flutter_tts');
  static FlutterTts? _activeInstance;
  static bool _platformCallHandlerInstalled = false;
  static final Map<String, FlutterTts> _utteranceOwners =
      <String, FlutterTts>{};

  VoidCallback? startHandler;
  VoidCallback? completionHandler;
  VoidCallback? pauseHandler;
  VoidCallback? continueHandler;
  VoidCallback? cancelHandler;
  ProgressHandler? progressHandler;
  ErrorHandler? errorHandler;
  UtteranceHandler? utteranceStartHandler;
  UtteranceHandler? utteranceCompletionHandler;
  UtteranceHandler? utterancePauseHandler;
  UtteranceHandler? utteranceContinueHandler;
  UtteranceHandler? utteranceCancelHandler;
  UtteranceProgressHandler? utteranceProgressHandler;
  UtteranceErrorHandler? utteranceErrorHandler;

  FlutterTts() {
    _ensurePlatformCallHandlerInstalled();
    _activeInstance ??= this;
  }

  static void _ensurePlatformCallHandlerInstalled() {
    if (_platformCallHandlerInstalled) {
      return;
    }
    _channel.setMethodCallHandler(_platformCallHandler);
    _platformCallHandlerInstalled = true;
  }

  static Future<dynamic> _platformCallHandler(MethodCall call) async {
    final utteranceId = _utteranceIdFromArguments(call.arguments);
    final instance =
        utteranceId == null ? _activeInstance : _utteranceOwners[utteranceId];
    try {
      return await instance?.platformCallHandler(call);
    } finally {
      if (utteranceId != null &&
          _isTerminalSpeechCallback(call.method) &&
          identical(_utteranceOwners[utteranceId], instance)) {
        _utteranceOwners.remove(utteranceId);
      }
    }
  }

  static String? _utteranceIdFromArguments(dynamic arguments) {
    if (arguments is! Map) {
      return null;
    }
    final value = arguments['utteranceId'];
    return value is String && value.isNotEmpty ? value : null;
  }

  static bool _isTerminalSpeechCallback(String method) =>
      method == 'speak.onComplete' ||
      method == 'speak.onCancel' ||
      method == 'speak.onError';

  void _activatePlatformCallHandler() {
    _ensurePlatformCallHandlerInstalled();
    _activeInstance = this;
  }

  Future<dynamic> _invokeSpeechOperation(
    String method,
    dynamic arguments, {
    String? utteranceId,
  }) async {
    final previousInstance = _activeInstance;
    final previousUtteranceOwner =
        utteranceId == null ? null : _utteranceOwners[utteranceId];
    _activatePlatformCallHandler();
    if (utteranceId != null) {
      _utteranceOwners[utteranceId] = this;
    }
    try {
      final nativeResult = await _channel.invokeMethod(method, arguments);
      final result = _SpeechOperationResult.fromNative(nativeResult);
      if (result.value == 0 && !result.wasAccepted) {
        _releaseRejectedSpeechOperation(
          previousInstance,
          utteranceId,
          previousUtteranceOwner,
        );
      }
      return result.value;
    } catch (_) {
      _releaseRejectedSpeechOperation(
        previousInstance,
        utteranceId,
        previousUtteranceOwner,
      );
      rethrow;
    }
  }

  void _releaseRejectedSpeechOperation(
    FlutterTts? previousInstance,
    String? utteranceId,
    FlutterTts? previousUtteranceOwner,
  ) {
    if (utteranceId != null && identical(_utteranceOwners[utteranceId], this)) {
      if (previousUtteranceOwner == null) {
        _utteranceOwners.remove(utteranceId);
      } else {
        _utteranceOwners[utteranceId] = previousUtteranceOwner;
      }
    }
    if (identical(_activeInstance, this)) {
      _activeInstance = previousInstance;
    }
  }

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get _isIOS => !kIsWeb && Platform.isIOS;
  static bool get _isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get _isWindows => !kIsWeb && Platform.isWindows;

  static void _throwUnsupported(String method, String platforms) {
    throw UnsupportedError('$method is only supported on $platforms.');
  }

  /// [Future] which sets speak's future to return on completion of the utterance
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async =>
      await _channel.invokeMethod('awaitSpeakCompletion', awaitCompletion);

  /// [Future] which sets synthesize to file's future to return on completion of the synthesize
  /// ***Android, iOS, and macOS supported only***
  Future<dynamic> awaitSynthCompletion(bool awaitCompletion) async {
    if (!_isAndroid && !_isIOS && !_isMacOS) {
      _throwUnsupported('awaitSynthCompletion', 'Android, iOS, and macOS');
    }
    return await _channel.invokeMethod('awaitSynthCompletion', awaitCompletion);
  }

  /// [Future] which invokes the platform specific method for speaking
  /// [utteranceId] is returned with every speech callback when supplied.
  ///
  /// Use a globally unique non-empty value for every logical utterance. Do not
  /// reuse an identifier for replacement speech, even immediately after
  /// [stop], because a delayed terminal callback may still be in flight. Pass
  /// the same identifier only when resuming that paused utterance.
  Future<dynamic> speak(
    String text, {
    bool focus = false,
    String? utteranceId,
  }) async {
    if (text.isEmpty) {
      return 0;
    }
    if (utteranceId != null && utteranceId.isEmpty) {
      throw ArgumentError.value(
        utteranceId,
        'utteranceId',
        'Must not be empty',
      );
    }
    if (_isAndroid) {
      final arguments = <String, dynamic>{"text": text, "focus": focus};
      if (utteranceId != null) {
        arguments["utteranceId"] = utteranceId;
      }
      return await _invokeSpeechOperation(
        'speak',
        arguments,
        utteranceId: utteranceId,
      );
    } else {
      final arguments = utteranceId == null
          ? text
          : <String, dynamic>{'text': text, 'utteranceId': utteranceId};
      return await _invokeSpeechOperation(
        'speak',
        arguments,
        utteranceId: utteranceId,
      );
    }
  }

  /// [Future] which invokes the platform specific method for pause
  Future<dynamic> pause() async {
    return await _channel.invokeMethod('pause');
  }

  /// [Future] which invokes the platform specific method for getMaxSpeechInputLength
  /// ***Android supported only***
  Future<int?> get getMaxSpeechInputLength async {
    if (!_isAndroid) {
      _throwUnsupported('getMaxSpeechInputLength', 'Android');
    }
    return await _channel.invokeMethod<int?>('getMaxSpeechInputLength');
  }

  /// [Future] which invokes the platform specific method for synthesizeToFile
  /// ***Android, iOS, and macOS supported only***
  Future<dynamic> synthesizeToFile(
    String text,
    String fileName, [
    bool isFullPath = false,
  ]) async {
    if (!_isAndroid && !_isIOS && !_isMacOS) {
      _throwUnsupported('synthesizeToFile', 'Android, iOS, and macOS');
    }
    return _invokeSpeechOperation('synthesizeToFile', <String, dynamic>{
      "text": text,
      "fileName": fileName,
      "isFullPath": isFullPath,
    });
  }

  /// [Future] which invokes the platform specific method for setLanguage
  Future<dynamic> setLanguage(String language) async =>
      await _channel.invokeMethod('setLanguage', language);

  /// [Future] which invokes the platform specific method for setSpeechRate
  /// Allowed values are in the range from 0.0 (slowest) to 1.0 (fastest)
  Future<dynamic> setSpeechRate(double rate) async =>
      await _channel.invokeMethod('setSpeechRate', rate);

  /// [Future] which invokes the platform specific method for setVolume
  /// Allowed values are in the range from 0.0 (silent) to 1.0 (loudest)
  Future<dynamic> setVolume(double volume) async =>
      await _channel.invokeMethod('setVolume', volume);

  /// [Future] which invokes the platform specific method for shared instance
  /// ***iOS supported only***
  Future<dynamic> setSharedInstance(bool sharedSession) async {
    if (!_isIOS) {
      _throwUnsupported('setSharedInstance', 'iOS');
    }
    return await _channel.invokeMethod('setSharedInstance', sharedSession);
  }

  /// [Future] which invokes the platform specific method for setting the autoStopSharedSession
  /// default value is true
  /// *** iOS, and macOS supported only***
  Future<dynamic> autoStopSharedSession(bool autoStop) async {
    if (!_isIOS && !_isMacOS) {
      _throwUnsupported('autoStopSharedSession', 'iOS and macOS');
    }
    return await _channel.invokeMethod('autoStopSharedSession', autoStop);
  }

  /// [Future] which invokes the platform specific method for setting audio category
  /// ***Ios supported only***
  Future<dynamic> setIosAudioCategory(
    IosTextToSpeechAudioCategory category,
    List<IosTextToSpeechAudioCategoryOptions> options, [
    IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode,
  ]) async {
    const categoryToString = <IosTextToSpeechAudioCategory, String>{
      IosTextToSpeechAudioCategory.ambientSolo: iosAudioCategoryAmbientSolo,
      IosTextToSpeechAudioCategory.ambient: iosAudioCategoryAmbient,
      IosTextToSpeechAudioCategory.playback: iosAudioCategoryPlayback,
      IosTextToSpeechAudioCategory.playAndRecord:
          iosAudioCategoryPlaybackAndRecord,
    };
    const optionsToString = {
      IosTextToSpeechAudioCategoryOptions.mixWithOthers:
          'iosAudioCategoryOptionsMixWithOthers',
      IosTextToSpeechAudioCategoryOptions.duckOthers:
          'iosAudioCategoryOptionsDuckOthers',
      IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers:
          'iosAudioCategoryOptionsInterruptSpokenAudioAndMixWithOthers',
      IosTextToSpeechAudioCategoryOptions.allowBluetooth:
          'iosAudioCategoryOptionsAllowBluetooth',
      IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP:
          'iosAudioCategoryOptionsAllowBluetoothA2DP',
      IosTextToSpeechAudioCategoryOptions.allowAirPlay:
          'iosAudioCategoryOptionsAllowAirPlay',
      IosTextToSpeechAudioCategoryOptions.defaultToSpeaker:
          'iosAudioCategoryOptionsDefaultToSpeaker',
    };
    const modeToString = <IosTextToSpeechAudioMode, String>{
      IosTextToSpeechAudioMode.defaultMode: iosAudioModeDefault,
      IosTextToSpeechAudioMode.gameChat: iosAudioModeGameChat,
      IosTextToSpeechAudioMode.measurement: iosAudioModeMeasurement,
      IosTextToSpeechAudioMode.moviePlayback: iosAudioModeMoviePlayback,
      IosTextToSpeechAudioMode.spokenAudio: iosAudioModeSpokenAudio,
      IosTextToSpeechAudioMode.videoChat: iosAudioModeVideoChat,
      IosTextToSpeechAudioMode.videoRecording: iosAudioModeVideoRecording,
      IosTextToSpeechAudioMode.voiceChat: iosAudioModeVoiceChat,
      IosTextToSpeechAudioMode.voicePrompt: iosAudioModeVoicePrompt,
    };
    if (!_isIOS) {
      _throwUnsupported('setIosAudioCategory', 'iOS');
    }
    return await _channel
        .invokeMethod<dynamic>('setIosAudioCategory', <String, dynamic>{
      iosAudioCategoryKey: categoryToString[category],
      iosAudioCategoryOptionsKey:
          options.map((o) => optionsToString[o]).toList(),
      iosAudioModeKey: modeToString[mode],
    });
  }

  /// [Future] which invokes the platform specific method for setEngine
  /// ***Android supported only***
  Future<dynamic> setEngine(String engine) async {
    if (!_isAndroid) {
      _throwUnsupported('setEngine', 'Android');
    }
    return await _channel.invokeMethod('setEngine', engine);
  }

  /// [Future] which invokes the platform specific method for setPitch
  /// 1.0 is default and ranges from .5 to 2.0
  Future<dynamic> setPitch(double pitch) async =>
      await _channel.invokeMethod('setPitch', pitch);

  /// [Future] which invokes the platform specific method for setVoice
  /// ***Android, iOS, macOS, Windows, and Web supported only***
  Future<dynamic> setVoice(Map<String, String> voice) async =>
      await _channel.invokeMethod('setVoice', voice);

  /// [Future] which resets the platform voice to the default
  Future<dynamic> clearVoice() async {
    if (!_isAndroid && !_isIOS && !_isMacOS) {
      _throwUnsupported('clearVoice', 'Android, iOS, and macOS');
    }
    return await _channel.invokeMethod('clearVoice');
  }

  /// [Future] which invokes the platform specific method for stop
  Future<dynamic> stop() async {
    return await _channel.invokeMethod('stop');
  }

  /// [Future] which invokes the platform specific method for getLanguages
  /// Android issues with API 21 & 22
  /// Returns a list of available languages
  Future<dynamic> get getLanguages async {
    final languages = await _channel.invokeMethod('getLanguages');
    return languages;
  }

  /// [Future] which invokes the platform specific method for getEngines
  /// Returns a list of installed TTS engines
  /// ***Android supported only***
  Future<dynamic> get getEngines async {
    if (!_isAndroid) {
      _throwUnsupported('getEngines', 'Android');
    }
    final engines = await _channel.invokeMethod('getEngines');
    return engines;
  }

  /// [Future] which invokes the platform specific method for getDefaultEngine
  /// Returns a `String` of the default engine name
  /// ***Android supported only ***
  Future<dynamic> get getDefaultEngine async {
    if (!_isAndroid) {
      _throwUnsupported('getDefaultEngine', 'Android');
    }
    final engineName = await _channel.invokeMethod('getDefaultEngine');
    return engineName;
  }

  /// [Future] which invokes the platform specific method for getDefaultVoice
  /// Returns a `Map` containing a voice name and locale
  /// ***Android supported only ***
  Future<dynamic> get getDefaultVoice async {
    if (!_isAndroid) {
      _throwUnsupported('getDefaultVoice', 'Android');
    }
    final voice = await _channel.invokeMethod('getDefaultVoice');
    return voice;
  }

  /// [Future] which invokes the platform specific method for getVoices
  /// Returns a `List` of `Maps` containing a voice name and locale
  /// For iOS specifically, it also includes quality, gender, and identifier
  /// ***Android, iOS, macOS, Windows, and Web supported only***
  Future<dynamic> get getVoices async {
    final voices = await _channel.invokeMethod('getVoices');
    return voices;
  }

  /// [Future] which invokes the platform specific method for isLanguageAvailable
  /// Returns `true` or `false`
  Future<dynamic> isLanguageAvailable(String language) async =>
      await _channel.invokeMethod('isLanguageAvailable', language);

  /// [Future] which invokes the platform specific method for isLanguageInstalled
  /// Returns `true` or `false`
  /// ***Android supported only***
  Future<dynamic> isLanguageInstalled(String language) async {
    if (!_isAndroid) {
      _throwUnsupported('isLanguageInstalled', 'Android');
    }
    return await _channel.invokeMethod('isLanguageInstalled', language);
  }

  /// [Future] which invokes the platform specific method for areLanguagesInstalled
  /// Returns a HashMap with `true` or `false` for each submitted language.
  /// ***Android supported only***
  Future<dynamic> areLanguagesInstalled(List<String> languages) async {
    if (!_isAndroid) {
      _throwUnsupported('areLanguagesInstalled', 'Android');
    }
    return await _channel.invokeMethod('areLanguagesInstalled', languages);
  }

  Future<SpeechRateValidRange> get getSpeechRateValidRange async {
    if (kIsWeb || _isWindows) {
      throw UnsupportedError(
        'getSpeechRateValidRange is only supported on Android, iOS, and macOS.',
      );
    }
    final validRange = await _channel.invokeMethod('getSpeechRateValidRange')
        as Map<dynamic, dynamic>;
    final min = double.parse(validRange['min'].toString());
    final normal = double.parse(validRange['normal'].toString());
    final max = double.parse(validRange['max'].toString());
    final platformStr = validRange['platform'].toString();
    final platform = TextToSpeechPlatform.values.firstWhere(
      (e) => e.name == platformStr,
    );

    return SpeechRateValidRange(min, normal, max, platform);
  }

  /// [Future] which invokes the platform specific method for setSilence
  /// 0 means start the utterance immediately. If the value is greater than zero a silence period in milliseconds is set according to the parameter
  /// ***Android supported only***
  Future<dynamic> setSilence(int timems) async {
    if (!_isAndroid) {
      _throwUnsupported('setSilence', 'Android');
    }
    return await _channel.invokeMethod('setSilence', timems);
  }

  /// [Future] which invokes the platform specific method for setQueueMode
  /// 0 means QUEUE_FLUSH - Queue mode where all entries in the playback queue (media to be played and text to be synthesized) are dropped and replaced by the new entry.
  /// Queues are flushed with respect to a given calling app. Entries in the queue from other calls are not discarded.
  /// 1 means QUEUE_ADD - Queue mode where the new entry is added at the end of the playback queue.
  /// ***Android supported only***
  Future<dynamic> setQueueMode(int queueMode) async {
    if (!_isAndroid) {
      _throwUnsupported('setQueueMode', 'Android');
    }
    return await _channel.invokeMethod('setQueueMode', queueMode);
  }

  void setStartHandler(VoidCallback callback) {
    startHandler = callback;
  }

  void setCompletionHandler(VoidCallback callback) {
    completionHandler = callback;
  }

  void setContinueHandler(VoidCallback callback) {
    continueHandler = callback;
  }

  void setPauseHandler(VoidCallback callback) {
    pauseHandler = callback;
  }

  void setCancelHandler(VoidCallback callback) {
    cancelHandler = callback;
  }

  void setProgressHandler(ProgressHandler callback) {
    progressHandler = callback;
  }

  void setErrorHandler(ErrorHandler handler) {
    errorHandler = handler;
  }

  /// Registers a start callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtteranceStartHandler(UtteranceHandler callback) {
    utteranceStartHandler = callback;
  }

  /// Registers a completion callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtteranceCompletionHandler(UtteranceHandler callback) {
    utteranceCompletionHandler = callback;
  }

  /// Registers a continue callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtteranceContinueHandler(UtteranceHandler callback) {
    utteranceContinueHandler = callback;
  }

  /// Registers a pause callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtterancePauseHandler(UtteranceHandler callback) {
    utterancePauseHandler = callback;
  }

  /// Registers a cancel callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtteranceCancelHandler(UtteranceHandler callback) {
    utteranceCancelHandler = callback;
  }

  /// Registers a progress callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtteranceProgressHandler(UtteranceProgressHandler callback) {
    utteranceProgressHandler = callback;
  }

  /// Registers an error callback that also receives the caller-supplied
  /// utterance identifier.
  void setUtteranceErrorHandler(UtteranceErrorHandler callback) {
    utteranceErrorHandler = callback;
  }

  /// Releases callback ownership held by this instance.
  ///
  /// Call [stop] first if speech should also be stopped. Native speech is not
  /// mutated by this synchronous cleanup method.
  void dispose() {
    _utteranceOwners.removeWhere((_, owner) => identical(owner, this));
    if (identical(_activeInstance, this)) {
      _activeInstance = null;
    }
    startHandler = null;
    completionHandler = null;
    pauseHandler = null;
    continueHandler = null;
    cancelHandler = null;
    progressHandler = null;
    errorHandler = null;
    utteranceStartHandler = null;
    utteranceCompletionHandler = null;
    utterancePauseHandler = null;
    utteranceContinueHandler = null;
    utteranceCancelHandler = null;
    utteranceProgressHandler = null;
    utteranceErrorHandler = null;
  }

  /// Platform listeners
  Future<dynamic> platformCallHandler(MethodCall call) async {
    final utteranceId = _utteranceIdFromArguments(call.arguments);
    switch (call.method) {
      case "speak.onStart":
        startHandler?.call();
        utteranceStartHandler?.call(utteranceId);
        break;

      case "synth.onStart":
        if (startHandler != null) {
          startHandler!();
        }
        break;
      case "speak.onComplete":
        completionHandler?.call();
        utteranceCompletionHandler?.call(utteranceId);
        break;
      case "synth.onComplete":
        if (completionHandler != null) {
          completionHandler!();
        }
        break;
      case "speak.onPause":
        pauseHandler?.call();
        utterancePauseHandler?.call(utteranceId);
        break;
      case "speak.onContinue":
        continueHandler?.call();
        utteranceContinueHandler?.call(utteranceId);
        break;
      case "speak.onCancel":
        cancelHandler?.call();
        utteranceCancelHandler?.call(utteranceId);
        break;
      case "speak.onError":
        final message = _errorMessageFromArguments(call.arguments);
        errorHandler?.call(message);
        utteranceErrorHandler?.call(utteranceId, message);
        break;
      case 'speak.onProgress':
        final progress = _progressFromArguments(call.arguments);
        if (progress != null) {
          progressHandler?.call(
            progress.text,
            progress.start,
            progress.end,
            progress.word,
          );
          utteranceProgressHandler?.call(
            utteranceId,
            progress.text,
            progress.start,
            progress.end,
            progress.word,
          );
        }
        break;
      case "synth.onError":
        if (errorHandler != null) {
          errorHandler!(call.arguments);
        }
        break;
      default:
        print('Unknown method ${call.method}');
    }
  }

  static dynamic _errorMessageFromArguments(dynamic arguments) {
    if (arguments is Map && arguments.containsKey('message')) {
      return arguments['message'];
    }
    return arguments;
  }

  static _ProgressEvent? _progressFromArguments(dynamic arguments) {
    if (arguments is! Map) {
      return null;
    }
    final text = arguments['text'];
    final start = _intFromValue(arguments['start']);
    final end = _intFromValue(arguments['end']);
    if (text is! String || start == null || end == null) {
      return null;
    }
    if (start < 0 || end <= start || end > text.length) {
      return null;
    }
    if (_splitsSurrogatePair(text, start) || _splitsSurrogatePair(text, end)) {
      return null;
    }
    final word = arguments['word'];
    return _ProgressEvent(
      text,
      start,
      end,
      word is String ? word : text.substring(start, end),
    );
  }

  static int? _intFromValue(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static bool _splitsSurrogatePair(String text, int offset) {
    if (offset <= 0 || offset >= text.length) {
      return false;
    }
    final previous = text.codeUnitAt(offset - 1);
    final current = text.codeUnitAt(offset);
    return previous >= 0xD800 &&
        previous <= 0xDBFF &&
        current >= 0xDC00 &&
        current <= 0xDFFF;
  }

  Future<void> setAudioAttributesForNavigation() async {
    if (!_isAndroid) {
      _throwUnsupported('setAudioAttributesForNavigation', 'Android');
    }
    await _channel.invokeMethod('setAudioAttributesForNavigation');
  }
}

class _ProgressEvent {
  final String text;
  final int start;
  final int end;
  final String word;

  const _ProgressEvent(this.text, this.start, this.end, this.word);
}

class _SpeechOperationResult {
  final dynamic value;
  final bool wasAccepted;

  const _SpeechOperationResult(this.value, this.wasAccepted);

  factory _SpeechOperationResult.fromNative(dynamic result) {
    if (result is Map &&
        result['accepted'] == true &&
        result.containsKey('value')) {
      return _SpeechOperationResult(result['value'], true);
    }
    return _SpeechOperationResult(result, false);
  }
}
