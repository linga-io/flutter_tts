import Flutter
import UIKit
import AVFoundation

public class SwiftFlutterTtsPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate {
  let iosAudioCategoryKey = "iosAudioCategoryKey"
  let iosAudioCategoryOptionsKey = "iosAudioCategoryOptionsKey"
  let iosAudioModeKey = "iosAudioModeKey"

  let synthesizer = AVSpeechSynthesizer()
  var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  var volume: Float = 1.0
  var pitch: Float = 1.0
  var voice: AVSpeechSynthesisVoice?
  var awaitSpeakCompletion: Bool = false
  var awaitSynthCompletion: Bool = false
  var autoStopSharedSession: Bool = true
  var speakResult: FlutterResult? = nil
  var synthResult: FlutterResult? = nil
  var synthesizeUtteranceIds = Set<ObjectIdentifier>()
  
  lazy var audioSession = AVAudioSession.sharedInstance()
  lazy var language: String = {
    AVSpeechSynthesisVoice.currentLanguageCode()
  }()
  lazy var languages: Set<String> = {
    Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
  }()
    

  var channel = FlutterMethodChannel()
  init(channel: FlutterMethodChannel) {
    super.init()
    self.channel = channel
    synthesizer.delegate = self
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_tts", binaryMessenger: registrar.messenger())
    let instance = SwiftFlutterTtsPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "speak":
      guard let text = call.arguments as? String else {
        result(FlutterError(code: "InvalidArgument", message: "speak requires a String argument", details: nil))
        return
      }
      self.speak(text: text, result: result)
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
    case "setSharedInstance":
      guard let sharedInstance = call.arguments as? Bool else {
        result(FlutterError(code: "InvalidArgument", message: "setSharedInstance requires a Bool argument", details: nil))
        return
      }
      self.setSharedInstance(sharedInstance: sharedInstance, result: result)
      break
    case "autoStopSharedSession":
      guard let autoStop = call.arguments as? Bool else {
        result(FlutterError(code: "InvalidArgument", message: "autoStopSharedSession requires a Bool argument", details: nil))
        return
      }
      self.autoStopSharedSession = autoStop
      result(1)
      break
    case "setIosAudioCategory":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "InvalidArgument", message: "setIosAudioCategory requires a map argument", details: nil))
        return
      }
      let audioCategory = args["iosAudioCategoryKey"] as? String
      let audioOptions = args[iosAudioCategoryOptionsKey] as? Array<String>
      let audioModes = args[iosAudioModeKey] as? String
      self.setAudioCategory(audioCategory: audioCategory, audioOptions: audioOptions, audioMode: audioModes, result: result)
      break
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func speak(text: String, result: @escaping FlutterResult) {
    if (self.synthesizer.isPaused) {
      if (self.synthesizer.continueSpeaking()) {
        if self.awaitSpeakCompletion && self.speakResult == nil {
          self.speakResult = result
        } else {
          result(1)
        }
      } else {
        result(0)
      }
    } else {
      if self.awaitSpeakCompletion && self.speakResult != nil {
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

      self.synthesizer.speak(utterance)
      if self.awaitSpeakCompletion {
        self.speakResult = result
      } else {
        result(1)
      }
    }
  }

  private func synthesizeToFile(text: String, fileName: String, isFullPath: Bool, result: @escaping FlutterResult) {
    var output: AVAudioFile?
    var completed = false
    let utterance = AVSpeechUtterance(string: text)
    let utteranceId = ObjectIdentifier(utterance)
    let shouldAwait = self.awaitSynthCompletion
    self.synthesizeUtteranceIds.insert(utteranceId)

    if self.voice != nil {
      utterance.voice = self.voice!
    } else {
      utterance.voice = AVSpeechSynthesisVoice(language: self.language)
    }
    utterance.rate = self.rate
    utterance.volume = self.volume
    utterance.pitchMultiplier = self.pitch

    func complete(_ value: Int) {
      if completed {
        return
      }
      completed = true
      DispatchQueue.main.async {
        if value == 1 {
          self.channel.invokeMethod("synth.onComplete", arguments: nil)
        } else {
          self.channel.invokeMethod("synth.onError", arguments: "Error synthesizing TTS to file")
        }
        if shouldAwait {
          result(value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
          self.synthesizeUtteranceIds.remove(utteranceId)
        }
      }
    }

    if #available(iOS 13.0, *) {
      self.channel.invokeMethod("synth.onStart", arguments: nil)
      self.synthesizer.write(utterance) { (buffer: AVAudioBuffer) in
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            NSLog("unknow buffer type: \(buffer)")
            complete(0)
            return
        }
        if pcmBuffer.frameLength == 0 {
            complete(1)
        } else {
          // append buffer to file
          let fileURL: URL
          if isFullPath {
              fileURL = URL(fileURLWithPath: fileName)
          } else {
              fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(fileName)
          }
          NSLog("Saving utterance to file: \(fileURL.absoluteString)")

        if output == nil {
          do {
            if #available(iOS 17.0, *) {
                guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcmBuffer.format.sampleRate, channels: pcmBuffer.format.channelCount, interleaved: false) else {
                NSLog("Error creating audio format for iOS 17+")
                complete(0)
                return
              }
              output = try AVAudioFile(forWriting: fileURL, settings: audioFormat.settings)
            } else {
              output = try AVAudioFile(forWriting: fileURL, settings: pcmBuffer.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
          } catch {
              NSLog("Error creating AVAudioFile: \(error.localizedDescription)")
              complete(0)
              return
          }
        }


          do {
            try output!.write(from: pcmBuffer)
          } catch {
            NSLog("Error writing AVAudioFile: \(error.localizedDescription)")
            complete(0)
          }
        }
      }
    } else {
        result(0)
        return
    }
    if !shouldAwait {
      result(1)
    }
  }

  private func pause(result: FlutterResult) {
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

  private func setSharedInstance(sharedInstance: Bool, result: FlutterResult) {
      do {
          try AVAudioSession.sharedInstance().setActive(sharedInstance)
          result(1)
      } catch {
          result(0)
      }
  }

  private func setAudioCategory(audioCategory: String?, audioOptions: Array<String>?, audioMode: String?, result: FlutterResult){
    let category: AVAudioSession.Category = AudioCategory(rawValue: audioCategory ?? "")?.toAVAudioSessionCategory() ?? audioSession.category
    let options: AVAudioSession.CategoryOptions = audioOptions?.reduce([], { (result, option) -> AVAudioSession.CategoryOptions in
      return result.union(AudioCategoryOptions(rawValue: option)?.toAVAudioSessionCategoryOptions() ?? [])}) ?? []
    do {
        if #available(iOS 12.0, *) {
            if audioMode == nil {
                try audioSession.setCategory(category, options: options)
            } else {
                let mode: AVAudioSession.Mode? = AudioModes(rawValue: audioMode ?? "")?.toAVAudioSessionMode() ?? AVAudioSession.Mode.default
                try audioSession.setCategory(category, mode: mode!, options: options)
            }
        } else {
            try audioSession.setCategory(category, options: options)
        }
      result(1)
    } catch {
      print(error)
      result(0)
    }
  }

  private func stop() {
    self.synthesizer.stopSpeaking(at: AVSpeechBoundary.immediate)
  }

  private func getLanguages(result: FlutterResult) {
    result(Array(self.languages))
  }

  private func getSpeechRateValidRange(result: FlutterResult) {
    let validSpeechRateRange: [String:String] = [
      "min": String(AVSpeechUtteranceMinimumSpeechRate),
      "normal": String(AVSpeechUtteranceDefaultSpeechRate),
      "max": String(AVSpeechUtteranceMaximumSpeechRate),
      "platform": "ios"
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
    if #available(iOS 9.0, *) {
      let voices = NSMutableArray()
      for voice in AVSpeechSynthesisVoice.speechVoices() {
        var voiceDict: [String: String] = [:]
        voiceDict["name"] = voice.name
        voiceDict["locale"] = voice.language
        voiceDict["quality"] = voice.quality.stringValue
        if #available(iOS 13.0, *) {
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
      if #available(iOS 9.0, *) {
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
                      let quality1 = voice1.quality
                      let quality2 = voice2.quality
                      
                      // macOS 13.0+ supports premium quality
                      if #available(iOS 16.0, *) {
                          if quality1 == .premium {
                              return true
                          } else if quality1 == .enhanced && quality2 != .premium {
                              return true
                          } else {
                              return false
                          }
                      } else {
                          // Fallback for macOS versions before 13.0 (no premium)
                          if quality1 == .enhanced {
                              return true
                          } else {
                              return false
                          }
                      }
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
      } else {
          // Handle older iOS versions if needed
          guard let name = voice["name"] else {
              result(0)
              return
          }
          setLanguage(language: name, result: result)
      }
  }

  private func clearVoice() {
    self.voice = nil
  }

  private func isSynthesizeToFileUtterance(_ utterance: AVSpeechUtterance) -> Bool {
    return self.synthesizeUtteranceIds.contains(ObjectIdentifier(utterance))
  }

  private func shouldDeactivateAndNotifyOthers(_ session: AVAudioSession) -> Bool {
    var options: AVAudioSession.CategoryOptions = .duckOthers
    if #available(iOS 9.0, *) {
      options.insert(.interruptSpokenAudioAndMixWithOthers)
    }
    options.remove(.mixWithOthers)

    return !options.isDisjoint(with: session.categoryOptions)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    if isSynthesizeToFileUtterance(utterance) {
      self.synthesizeUtteranceIds.remove(ObjectIdentifier(utterance))
      return
    }
    if shouldDeactivateAndNotifyOthers(audioSession) && self.autoStopSharedSession {
      do {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        print(error)
      }
    }
    if self.awaitSpeakCompletion && self.speakResult != nil {
        self.speakResult!(1)
        self.speakResult = nil
    }
    if self.awaitSynthCompletion && self.synthResult != nil {
      self.synthResult!(1)
      self.synthResult = nil
    }
    self.channel.invokeMethod("speak.onComplete", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    if isSynthesizeToFileUtterance(utterance) {
      return
    }
    self.channel.invokeMethod("speak.onStart", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
    if isSynthesizeToFileUtterance(utterance) {
      return
    }
    self.channel.invokeMethod("speak.onPause", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
    if isSynthesizeToFileUtterance(utterance) {
      return
    }
    self.channel.invokeMethod("speak.onContinue", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    if isSynthesizeToFileUtterance(utterance) {
      self.synthesizeUtteranceIds.remove(ObjectIdentifier(utterance))
      return
    }
    if self.awaitSpeakCompletion && self.speakResult != nil {
      self.speakResult!(0)
      self.speakResult = nil
    }
    self.channel.invokeMethod("speak.onCancel", arguments: nil)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
    if isSynthesizeToFileUtterance(utterance) {
      return
    }
    let nsWord = utterance.speechString as NSString
    let data: [String:String] = [
      "text": utterance.speechString,
      "start": String(characterRange.location),
      "end": String(characterRange.location + characterRange.length),
      "word": nsWord.substring(with: characterRange)
    ]
    self.channel.invokeMethod("speak.onProgress", arguments: data)
  }

}

extension AVSpeechSynthesisVoiceQuality {
    var stringValue: String {
        switch self {
        case .default:
            return "default"
        case .premium:
            return "premium"
        case .enhanced:
            return "enhanced"
        @unknown default:
            return "unknown"
        }
    }
}

@available(iOS 13.0, *)
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
