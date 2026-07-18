import FlutterMacOS
import Foundation
import AVFoundation

private final class SpeechUtteranceContext {
  let utteranceId: String?
  private var awaitedResult: FlutterResult?

  init(utteranceId: String?, awaitedResult: FlutterResult?) {
    self.utteranceId = utteranceId
    self.awaitedResult = awaitedResult
  }

  var isAwaitingResult: Bool {
    awaitedResult != nil
  }

  func attachAwaitedResultIfAbsent(_ result: @escaping FlutterResult) -> Bool {
    guard awaitedResult == nil else {
      return false
    }
    awaitedResult = result
    return true
  }

  func resolveAwaitedResult(_ value: Int) {
    let result = awaitedResult
    awaitedResult = nil
    if utteranceId == nil {
      result?(value)
    } else {
      result?(["accepted": true, "value": value])
    }
  }
}

private struct SynthesisCompletion {
  let value: Int
  let awaitedResult: FlutterResult?
}

private final class SynthesisContext: @unchecked Sendable {
  let utterance: AVSpeechUtterance
  private let destinationURL: URL
  private let temporaryURL: URL
  private let lock = NSLock()
  private var awaitedResult: FlutterResult?
  private var outputFile: AVAudioFile?
  private var isCompleted = false
  private var hasWriteFailure = false
  private var hasWrittenAudio = false

  init(
    utterance: AVSpeechUtterance,
    destinationURL: URL,
    awaitedResult: FlutterResult?
  ) {
    self.utterance = utterance
    self.destinationURL = destinationURL
    self.awaitedResult = awaitedResult

    let pathExtension = destinationURL.pathExtension
    let temporaryName = ".flutter_tts_\(UUID().uuidString)" +
      (pathExtension.isEmpty ? "" : ".\(pathExtension)")
    self.temporaryURL = destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent(temporaryName, isDirectory: false)
  }

  func write(
    _ buffer: AVAudioPCMBuffer,
    createOutput: (URL) throws -> AVAudioFile
  ) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard !isCompleted else {
      return false
    }

    do {
      if outputFile == nil {
        outputFile = try createOutput(temporaryURL)
      }
      try outputFile?.write(from: buffer)
      hasWrittenAudio = true
      return true
    } catch {
      hasWriteFailure = true
      throw error
    }
  }

  func finish(requestedValue: Int) -> SynthesisCompletion? {
    lock.lock()
    defer { lock.unlock() }

    guard !isCompleted else {
      return nil
    }

    isCompleted = true
    // AVAudioFile has no explicit close API. Releasing the final reference
    // closes it before the temporary file is committed or removed.
    outputFile = nil
    var value = 0
    if requestedValue == 1 && hasWrittenAudio && !hasWriteFailure {
      do {
        try commitTemporaryFile()
        value = 1
      } catch {
        NSLog("Error committing synthesized audio file: \(error.localizedDescription)")
        removeTemporaryFile()
      }
    } else {
      removeTemporaryFile()
    }
    let result = awaitedResult
    awaitedResult = nil
    return SynthesisCompletion(value: value, awaitedResult: result)
  }

  private func commitTemporaryFile() throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destinationURL.path) {
      do {
        _ = try fileManager.replaceItemAt(
          destinationURL,
          withItemAt: temporaryURL,
          backupItemName: nil,
          options: []
        )
        return
      } catch {
        guard fileManager.fileExists(atPath: temporaryURL.path),
              !fileManager.fileExists(atPath: destinationURL.path) else {
          throw error
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return
      }
    }

    do {
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    } catch {
      guard fileManager.fileExists(atPath: temporaryURL.path),
            fileManager.fileExists(atPath: destinationURL.path) else {
        throw error
      }
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: temporaryURL,
        backupItemName: nil,
        options: []
      )
    }
  }

  private func removeTemporaryFile() {
    guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
      return
    }
    do {
      try FileManager.default.removeItem(at: temporaryURL)
    } catch {
      NSLog("Error removing temporary synthesized audio file: \(error.localizedDescription)")
    }
  }
}

// Flutter method calls and mutable plugin state are main-thread confined. The
// speech delegate is Sendable, so its callbacks snapshot only Sendable values
// and marshal state access back to the main thread below.
public final class FlutterTtsPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  final var iosAudioCategoryKey = "iosAudioCategoryKey"
  final var iosAudioCategoryOptionsKey = "iosAudioCategoryOptionsKey"

  let synthesizer = AVSpeechSynthesizer()
  var language: String = AVSpeechSynthesisVoice.currentLanguageCode()
  var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  var languages = Set<String>()
  var volume: Float = 1.0
  var pitch: Float = 1.0
  var voice: AVSpeechSynthesisVoice?
  var awaitSpeakCompletion: Bool = false
  var awaitSynthCompletion: Bool = false
  private var speechUtteranceContexts = [ObjectIdentifier: SpeechUtteranceContext]()
  private var activeSpeechUtteranceKey: ObjectIdentifier?
  private var synthesisContexts = [ObjectIdentifier: SynthesisContext]()

  var channel = FlutterMethodChannel()
  init(channel: FlutterMethodChannel) {
    super.init()
    self.channel = channel
    synthesizer.delegate = self
    setLanguages()
  }

  private func setLanguages() {
    for voice in AVSpeechSynthesisVoice.speechVoices(){
      self.languages.insert(voice.language)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_tts", binaryMessenger: registrar.messenger)
    let instance = FlutterTtsPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "speak":
      let text: String
      let utteranceId: String?
      if let legacyText = call.arguments as? String {
        text = legacyText
        utteranceId = nil
      } else if let args = call.arguments as? [String: Any],
                let mappedText = args["text"] as? String {
        text = mappedText
        if let rawUtteranceId = args["utteranceId"] {
          guard let mappedUtteranceId = rawUtteranceId as? String,
                !mappedUtteranceId.isEmpty else {
            result(FlutterError(code: "InvalidArgument", message: "speak utteranceId must be a non-empty String", details: nil))
            return
          }
          utteranceId = mappedUtteranceId
        } else {
          utteranceId = nil
        }
      } else {
        result(FlutterError(code: "InvalidArgument", message: "speak requires a String or a map containing text", details: nil))
        return
      }
      self.speak(text: text, utteranceId: utteranceId, result: result)
      break
    case "awaitSpeakCompletion":
      guard let awaitCompletion = call.arguments as? Bool else {
        result(FlutterError(code: "InvalidArgument", message: "awaitSpeakCompletion requires a Bool argument", details: nil))
        return
      }
      self.awaitSpeakCompletion = awaitCompletion
      result(1)
      break
    case "awaitSynthCompletion":
      guard let awaitCompletion = call.arguments as? Bool else {
        result(FlutterError(code: "InvalidArgument", message: "awaitSynthCompletion requires a Bool argument", details: nil))
        return
      }
      self.awaitSynthCompletion = awaitCompletion
      result(1)
      break
    case "synthesizeToFile":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "InvalidArgument", message: "synthesizeToFile requires a map argument", details: nil))
        return
      }
      guard let text = args["text"] as? String,
            let fileName = args["fileName"] as? String else {
        result(FlutterError(code: "InvalidArgument", message: "synthesizeToFile requires text and fileName arguments", details: nil))
        return
      }
      let isFullPath = args["isFullPath"] as? Bool ?? false
      self.synthesizeToFile(text: text, fileName: fileName, isFullPath: isFullPath, result: result)
      break
    case "pause":
      self.pause(result: result)
      break
    case "setLanguage":
      guard let language = call.arguments as? String else {
        result(FlutterError(code: "InvalidArgument", message: "setLanguage requires a String argument", details: nil))
        return
      }
      self.setLanguage(language: language, result: result)
      break
    case "setSpeechRate":
      guard let rate = call.arguments as? Double else {
        result(FlutterError(code: "InvalidArgument", message: "setSpeechRate requires a double argument", details: nil))
        return
      }
      self.setRate(rate: Float(rate))
      result(1)
      break
    case "setVolume":
      guard let volume = call.arguments as? Double else {
        result(FlutterError(code: "InvalidArgument", message: "setVolume requires a double argument", details: nil))
        return
      }
      self.setVolume(volume: Float(volume), result: result)
      break
    case "setPitch":
      guard let pitch = call.arguments as? Double else {
        result(FlutterError(code: "InvalidArgument", message: "setPitch requires a double argument", details: nil))
        return
      }
      self.setPitch(pitch: Float(pitch), result: result)
      break
    case "stop":
      self.stop()
      result(1)
      break
    case "getLanguages":
      self.getLanguages(result: result)
      break
    case "getSpeechRateValidRange":
      self.getSpeechRateValidRange(result: result)
      break
    case "isLanguageAvailable":
      guard let language = call.arguments as? String else {
        result(FlutterError(code: "InvalidArgument", message: "isLanguageAvailable requires a String argument", details: nil))
        return
      }
      self.isLanguageAvailable(language: language, result: result)
      break
    case "getVoices":
      self.getVoices(result: result)
      break
    case "setVoice":
      guard let args = call.arguments as? [String: String] else {
        result(FlutterError(code: "InvalidArgument", message: "setVoice requires a string map argument", details: nil))
        return
      }
      self.setVoice(voice: args, result: result)
      break
    case "clearVoice":
      self.clearVoice()
      result(1)
      break
    case "autoStopSharedSession":
      // MacOS does not have a shared audio session so just accept the call
      result(1)
      break
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func speak(text: String, utteranceId: String?, result: @escaping FlutterResult) {
    if (self.synthesizer.isPaused) {
      guard let activeSpeechUtteranceKey = self.activeSpeechUtteranceKey,
            let activeContext = self.speechUtteranceContexts[activeSpeechUtteranceKey],
            activeContext.utteranceId == utteranceId else {
        result(0)
        return
      }
      if (self.synthesizer.continueSpeaking()) {
        if self.awaitSpeakCompletion,
           activeContext.attachAwaitedResultIfAbsent(result) {
          return
        }
        result(1)
      } else {
        result(0)
      }
    } else {
      if let utteranceId = utteranceId,
         self.speechUtteranceContexts.values.contains(where: { $0.utteranceId == utteranceId }) {
        result(0)
        return
      }
      if self.awaitSpeakCompletion && self.speechUtteranceContexts.values.contains(where: { $0.isAwaitingResult }) {
        result(0)
        return
      }
      let utterance = AVSpeechUtterance(string: text)
      if self.voice != nil {
        utterance.voice = self.voice!
      } else {
        utterance.voice = AVSpeechSynthesisVoice(language: self.language)
      }
      utterance.rate = self.rate
      utterance.volume = self.volume
      utterance.pitchMultiplier = self.pitch

      let shouldAwait = self.awaitSpeakCompletion
      let utteranceKey = ObjectIdentifier(utterance)
      self.speechUtteranceContexts[utteranceKey] = SpeechUtteranceContext(
        utteranceId: utteranceId,
        awaitedResult: shouldAwait ? result : nil
      )
      self.synthesizer.speak(utterance)
      if !shouldAwait {
        result(1)
      }
    }
  }

  private func synthesizeToFile(text: String, fileName: String, isFullPath: Bool, result: @escaping FlutterResult) {
    guard #available(macOS 10.15, *) else {
      result(0)
      return
    }
    guard !text.isEmpty,
          !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !fileName.contains("\0") else {
      result(0)
      return
    }

    let fileURL: URL
    if isFullPath {
      fileURL = URL(fileURLWithPath: fileName)
    } else {
      guard fileName != ".",
            fileName != "..",
            !fileName.contains("/"),
            !fileName.contains("\\") else {
        result(0)
        return
      }
      guard let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first else {
        result(0)
        return
      }
      fileURL = documentsURL.appendingPathComponent(fileName)
    }

    let utterance = AVSpeechUtterance(string: text)
    let shouldAwait = self.awaitSynthCompletion

    if self.voice != nil {
      utterance.voice = self.voice!
    } else {
      utterance.voice = AVSpeechSynthesisVoice(language: self.language)
    }
    utterance.rate = self.rate
    utterance.volume = self.volume
    utterance.pitchMultiplier = self.pitch

    let utteranceKey = ObjectIdentifier(utterance)
    let context = SynthesisContext(
      utterance: utterance,
      destinationURL: fileURL,
      awaitedResult: shouldAwait ? result : nil
    )
    self.synthesisContexts[utteranceKey] = context

    self.channel.invokeMethod("synth.onStart", arguments: nil)
    self.synthesizer.write(utterance) { (buffer: AVAudioBuffer) in
      guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
        NSLog("Unknown synthesis buffer type: \(buffer)")
        self.completeSynthesis(context, key: utteranceKey, requestedValue: 0)
        return
      }
      if pcmBuffer.frameLength == 0 {
        self.completeSynthesis(context, key: utteranceKey, requestedValue: 1)
        return
      }

      do {
        let didWrite = try context.write(pcmBuffer) { temporaryURL in
          NSLog("Saving utterance to file: \(fileURL.absoluteString)")
          return try AVAudioFile(
            forWriting: temporaryURL,
            settings: pcmBuffer.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
          )
        }
        if !didWrite {
          return
        }
      } catch {
        NSLog("Error writing synthesized audio file: \(error.localizedDescription)")
        self.completeSynthesis(context, key: utteranceKey, requestedValue: 0)
      }
    }

    if !shouldAwait {
      result(1)
    }
  }

  private func completeSynthesis(
    _ context: SynthesisContext,
    key: ObjectIdentifier,
    requestedValue: Int
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.completeSynthesis(context, key: key, requestedValue: requestedValue)
      }
      return
    }

    guard let registeredContext = self.synthesisContexts[key],
          registeredContext === context else {
      return
    }
    self.synthesisContexts.removeValue(forKey: key)

    guard let completion = context.finish(requestedValue: requestedValue) else {
      return
    }
    if completion.value == 1 {
      self.channel.invokeMethod("synth.onComplete", arguments: nil)
    } else {
      self.channel.invokeMethod("synth.onError", arguments: "Error synthesizing TTS to file")
    }
    completion.awaitedResult?(completion.value)
  }

  private func pause(result: FlutterResult) {
    guard let activeSpeechUtteranceKey = self.activeSpeechUtteranceKey,
          self.speechUtteranceContexts[activeSpeechUtteranceKey] != nil else {
      result(0)
      return
    }
    if (self.synthesizer.pauseSpeaking(at: AVSpeechBoundary.word)) {
      result(1)
    } else {
      result(0)
    }
  }

  private func setLanguage(language: String, result: FlutterResult) {
    if !(self.languages.contains(where: {$0.range(of: language, options: [.caseInsensitive, .anchored]) != nil})) {
      result(0)
    } else {
      self.language = language
      self.voice = nil
      result(1)
    }
  }

  private func setRate(rate: Float) {
    self.rate = rate
  }

  private func setVolume(volume: Float, result: FlutterResult) {
    if (volume >= 0.0 && volume <= 1.0) {
      self.volume = volume
      result(1)
    } else {
      result(0)
    }
  }

  private func setPitch(pitch: Float, result: FlutterResult) {
    if (pitch >= 0.5 && pitch <= 2.0) {
      self.pitch = pitch
      result(1)
    } else {
      result(0)
    }
  }

  private func stop() {
    let contexts = Array(self.speechUtteranceContexts.values)
    let synthesisEntries = Array(self.synthesisContexts)
    self.speechUtteranceContexts.removeAll()
    self.activeSpeechUtteranceKey = nil
    self.synthesizer.stopSpeaking(at: AVSpeechBoundary.immediate)
    for context in contexts {
      context.resolveAwaitedResult(0)
      self.channel.invokeMethod("speak.onCancel", arguments: speechEventArguments(for: context))
    }
    for (key, context) in synthesisEntries {
      completeSynthesis(context, key: key, requestedValue: 0)
    }
  }

  private func getLanguages(result: FlutterResult) {
    result(Array(self.languages))
  }

  private func getSpeechRateValidRange(result: FlutterResult) {
    let validSpeechRateRange: [String:String] = [
      "min": String(AVSpeechUtteranceMinimumSpeechRate),
      "normal": String(AVSpeechUtteranceDefaultSpeechRate),
      "max": String(AVSpeechUtteranceMaximumSpeechRate),
      "platform": "macos"
    ]
    result(validSpeechRateRange)
  }

  private func isLanguageAvailable(language: String, result: FlutterResult) {
    var isAvailable: Bool = false
    if (self.languages.contains(where: {$0.range(of: language, options: [.caseInsensitive, .anchored]) != nil})) {
      isAvailable = true
    }
    result(isAvailable);
  }

  private func getVoices(result: FlutterResult) {
    if #available(macOS 10.15, *) {
      let voices = NSMutableArray()
      for voice in AVSpeechSynthesisVoice.speechVoices() {
        var voiceDict: [String: String] = [:]
        voiceDict["name"] = voice.name
        voiceDict["locale"] = voice.language
        voiceDict["quality"] = voice.quality.stringValue
        if #available(macOS 10.15, *) {
          voiceDict["gender"] = voice.gender.stringValue
        }
        voiceDict["identifier"] = voice.identifier
        voices.add(voiceDict)
      }
      result(voices)
    } else {
      // Since voice selection is not supported below iOS 9, make voice getter and setter
      // have the same bahavior as language selection.
      getLanguages(result: result)
    }
  }



  private func setVoice(voice: [String: String], result: FlutterResult) {
      // Check if identifier exists and is not empty
      if let identifier = voice["identifier"], !identifier.isEmpty {
          // Find the voice by identifier
          if let selectedVoice = AVSpeechSynthesisVoice(identifier: identifier) {
              self.voice = selectedVoice
              self.language = selectedVoice.language
              result(1)
              return
          }
      }

      // If no valid identifier, search by name and locale, then prioritize by quality
      if let name = voice["name"], let locale = voice["locale"] {
          let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.name == name && $0.language == locale }

          if !matchingVoices.isEmpty {
              // Sort voices by quality: premium (if available) > enhanced > others
              let sortedVoices = matchingVoices.sorted { (voice1, voice2) -> Bool in
                  let qualityRank1 = voice1.quality.preferenceRank
                  let qualityRank2 = voice2.quality.preferenceRank
                  if qualityRank1 != qualityRank2 {
                      return qualityRank1 > qualityRank2
                  }
                  return voice1.identifier < voice2.identifier
              }

              // Select the highest quality voice
              if let selectedVoice = sortedVoices.first {
                  self.voice = selectedVoice
                  self.language = selectedVoice.language
                  result(1)
                  return
              }
          }
      }

      // No matching voice found
      result(0)
  }

  private func clearVoice() {
    self.voice = nil
  }

  private func speechEventArguments(for context: SpeechUtteranceContext?) -> [String: String]? {
    guard let utteranceId = context?.utteranceId else {
      return nil
    }
    return ["utteranceId": utteranceId]
  }

  private func dispatchSpeechDelegateCallback(
    _ callback: @escaping @Sendable (FlutterTtsPlugin) -> Void
  ) {
    if Thread.isMainThread {
      callback(self)
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      callback(self)
    }
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let utteranceKey = ObjectIdentifier(utterance)
    dispatchSpeechDelegateCallback { plugin in
      plugin.handleSpeechDidFinish(utteranceKey)
    }
  }

  private func handleSpeechDidFinish(_ utteranceKey: ObjectIdentifier) {
    if let context = self.synthesisContexts[utteranceKey] {
      completeSynthesis(context, key: utteranceKey, requestedValue: 1)
      return
    }
    guard let context = self.speechUtteranceContexts.removeValue(forKey: utteranceKey) else {
      return
    }
    if self.activeSpeechUtteranceKey == utteranceKey {
      self.activeSpeechUtteranceKey = nil
    }
    context.resolveAwaitedResult(1)
    self.channel.invokeMethod("speak.onComplete", arguments: speechEventArguments(for: context))
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let utteranceKey = ObjectIdentifier(utterance)
    dispatchSpeechDelegateCallback { plugin in
      plugin.handleSpeechStateEvent("speak.onStart", utteranceKey: utteranceKey)
    }
  }

  private func handleSpeechStateEvent(_ method: String, utteranceKey: ObjectIdentifier) {
    if self.synthesisContexts[utteranceKey] != nil {
      return
    }
    guard let context = self.speechUtteranceContexts[utteranceKey] else {
      return
    }
    self.activeSpeechUtteranceKey = utteranceKey
    self.channel.invokeMethod(method, arguments: speechEventArguments(for: context))
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
    let utteranceKey = ObjectIdentifier(utterance)
    dispatchSpeechDelegateCallback { plugin in
      plugin.handleSpeechStateEvent("speak.onPause", utteranceKey: utteranceKey)
    }
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
    let utteranceKey = ObjectIdentifier(utterance)
    dispatchSpeechDelegateCallback { plugin in
      plugin.handleSpeechStateEvent("speak.onContinue", utteranceKey: utteranceKey)
    }
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let utteranceKey = ObjectIdentifier(utterance)
    dispatchSpeechDelegateCallback { plugin in
      plugin.handleSpeechDidCancel(utteranceKey)
    }
  }

  private func handleSpeechDidCancel(_ utteranceKey: ObjectIdentifier) {
    if let context = self.synthesisContexts[utteranceKey] {
      completeSynthesis(context, key: utteranceKey, requestedValue: 0)
      return
    }
    guard let context = self.speechUtteranceContexts.removeValue(forKey: utteranceKey) else {
      return
    }
    if self.activeSpeechUtteranceKey == utteranceKey {
      self.activeSpeechUtteranceKey = nil
    }
    context.resolveAwaitedResult(0)
    self.channel.invokeMethod("speak.onCancel", arguments: speechEventArguments(for: context))
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
    let utteranceKey = ObjectIdentifier(utterance)
    let speechString = utterance.speechString
    dispatchSpeechDelegateCallback { plugin in
      plugin.handleSpeechProgress(
        utteranceKey: utteranceKey,
        characterRange: characterRange,
        speechString: speechString
      )
    }
  }

  private func handleSpeechProgress(
    utteranceKey: ObjectIdentifier,
    characterRange: NSRange,
    speechString: String
  ) {
    if self.synthesisContexts[utteranceKey] != nil {
      return
    }
    let nsWord = speechString as NSString
    guard let context = self.speechUtteranceContexts[utteranceKey] else {
      return
    }
    guard characterRange.location != NSNotFound,
          characterRange.location >= 0,
          characterRange.length >= 0,
          characterRange.location <= nsWord.length,
          characterRange.length <= nsWord.length - characterRange.location else {
      return
    }
    var data: [String:String] = [
      "text": speechString,
      "start": String(characterRange.location),
      "end": String(characterRange.location + characterRange.length),
      "word": nsWord.substring(with: characterRange)
    ]
    if let utteranceId = context.utteranceId {
      data["utteranceId"] = utteranceId
    }
    self.channel.invokeMethod("speak.onProgress", arguments: data)
  }

}

extension AVSpeechSynthesisVoiceQuality {
    var preferenceRank: Int {
        if #available(macOS 13.0, *), self == .premium {
            return 2
        }
        return self == .enhanced ? 1 : 0
    }

    var stringValue: String {
        switch self {
        case .default:
            return "default"
        case .enhanced:
            return "enhanced"
        default:
            if #available(macOS 13.0, *), self == .premium {
                return "premium"
            }
            return "unknown"
        }
    }
}

@available(macOS 10.15, *)
extension AVSpeechSynthesisVoiceGender {
    var stringValue: String {
        switch self {
        case .male:
            return "male"
        case .female:
            return "female"
        case .unspecified:
            return "unspecified"
        @unknown default:
            return "unknown"
        }
    }
}
