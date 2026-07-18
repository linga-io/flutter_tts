#include "include/flutter_tts/flutter_tts_plugin.h"
// This must be included before many other Windows headers.
#include <windows.h>
#include <VersionHelpers.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <exception>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

typedef std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> FlutterResult;
//typedef flutter::MethodResult<flutter::EncodableValue>* PFlutterResult;

const UINT kFlutterTtsAsyncDispatchMessage = RegisterWindowMessageW(
	L"FlutterTts.AsyncDispatch.8E6750D2-44B8-44E8-9EA0-0CA08A37AB97");

namespace {
	struct SpeakArguments {
		std::string text;
		std::optional<std::string> utteranceId;
	};

	// Native TTS callbacks are delivered on worker threads. This queue is the
	// only bridge from those callbacks to Flutter's platform thread. Its shared
	// lifetime lets callbacks safely outlive the plugin, while Shutdown prevents
	// them from reaching a destroyed method channel.
	template <typename Event>
	class PlatformEventQueue
		: public std::enable_shared_from_this<PlatformEventQueue<Event>> {
	public:
		explicit PlatformEventQueue(HWND viewWindowHandle)
			: viewWindowHandle_(viewWindowHandle) {}

		bool IsAvailable() const {
			std::lock_guard<std::mutex> lock(mutex_);
			return acceptingEvents_ && ResolveTargetWindowLocked() != nullptr &&
				kFlutterTtsAsyncDispatchMessage != 0;
		}

		bool Enqueue(Event event) {
			HWND windowHandle = nullptr;
			bool shouldSignal = false;
			{
				std::lock_guard<std::mutex> lock(mutex_);
				windowHandle = ResolveTargetWindowLocked();
				if (!acceptingEvents_ || windowHandle == nullptr ||
					kFlutterTtsAsyncDispatchMessage == 0) {
					return false;
				}
				events_.push_back(std::move(event));
				if (!wakePending_ && !retryRunning_) {
					wakePending_ = true;
					shouldSignal = true;
				}
			}

			if (!shouldSignal) {
				return true;
			}
			if (SignalPlatformThread(windowHandle)) {
				return true;
			}

			return StartRetryAfterSignalFailure();
		}

		bool HandlesMessage(UINT message, WPARAM wparam) const {
			return message == kFlutterTtsAsyncDispatchMessage &&
				wparam == reinterpret_cast<WPARAM>(this);
		}

		std::vector<Event> TakePending() {
			std::vector<Event> pending;
			{
				std::lock_guard<std::mutex> lock(mutex_);
				pending.reserve(events_.size());
				while (!events_.empty()) {
					pending.push_back(std::move(events_.front()));
					events_.pop_front();
				}
				wakePending_ = false;
			}
			return pending;
		}

		void Shutdown() {
			{
				std::lock_guard<std::mutex> lock(mutex_);
				if (!acceptingEvents_) {
					return;
				}
				acceptingEvents_ = false;
				viewWindowHandle_ = nullptr;
				events_.clear();
				wakePending_ = false;
			}
		}

	private:
		bool SignalPlatformThread(HWND windowHandle) const {
			if (PostMessage(
					windowHandle,
					kFlutterTtsAsyncDispatchMessage,
					reinterpret_cast<WPARAM>(this),
					0)) {
				return true;
			}

			// PostMessage can fail when the window message queue is full.
			// SendNotifyMessage bypasses that queue and returns immediately when
			// crossing threads, unlike SendMessage, so it cannot create a teardown
			// wait cycle with a native callback. The window procedure still runs on
			// the platform thread; this worker only requests that dispatch.
			return SendNotifyMessage(
				windowHandle,
				kFlutterTtsAsyncDispatchMessage,
				reinterpret_cast<WPARAM>(this),
				0) != 0;
		}

		bool StartRetryAfterSignalFailure() {
			try {
				auto queue = this->shared_from_this();
				std::lock_guard<std::mutex> lock(mutex_);
				wakePending_ = false;
				if (!acceptingEvents_ || events_.empty()) {
					return false;
				}
				if (retryRunning_) {
					return true;
				}
				retryRunning_ = true;
				std::thread([queue = std::move(queue)]() {
					queue->RetrySignalLoop();
				}).detach();
				return true;
			} catch (...) {
				std::lock_guard<std::mutex> lock(mutex_);
				retryRunning_ = false;
				return false;
			}
		}

		void RetrySignalLoop() {
			constexpr auto retryDelay = std::chrono::milliseconds(10);
			while (true) {
				std::this_thread::sleep_for(retryDelay);

				HWND windowHandle = nullptr;
				{
					std::lock_guard<std::mutex> lock(mutex_);
					if (!acceptingEvents_ || events_.empty()) {
						retryRunning_ = false;
						return;
					}
					windowHandle = ResolveTargetWindowLocked();
					if (windowHandle == nullptr) {
						continue;
					}

					// Publish the pending-wake state before signaling. An event queued
					// concurrently will then be covered by this same platform message.
					retryRunning_ = false;
					wakePending_ = true;
				}

				if (SignalPlatformThread(windowHandle)) {
					return;
				}

				{
					std::lock_guard<std::mutex> lock(mutex_);
					wakePending_ = false;
					if (!acceptingEvents_ || events_.empty()) {
						return;
					}
					retryRunning_ = true;
				}
			}
		}

		HWND ResolveTargetWindowLocked() const {
			if (viewWindowHandle_ == nullptr || !IsWindow(viewWindowHandle_)) {
				return nullptr;
			}
			const HWND rootWindow = GetAncestor(viewWindowHandle_, GA_ROOT);
			if (rootWindow == nullptr) {
				return nullptr;
			}
			// Standard Flutter runners register plugins before parenting the child
			// Flutter view. Until it has a root host window, the top-level window
			// procedure delegate cannot receive our dispatch message.
			if (rootWindow == viewWindowHandle_ &&
				(GetWindowLongPtr(viewWindowHandle_, GWL_STYLE) & WS_CHILD) != 0) {
				return nullptr;
			}
			return rootWindow;
		}

		mutable std::mutex mutex_;
		HWND viewWindowHandle_;
		bool acceptingEvents_ = true;
		bool wakePending_ = false;
		bool retryRunning_ = false;
		std::deque<Event> events_;
	};

	std::optional<SpeakArguments> parseSpeakArguments(
		const flutter::EncodableValue& arguments) {
		if (std::holds_alternative<std::string>(arguments)) {
			return SpeakArguments{std::get<std::string>(arguments), std::nullopt};
		}
		if (!std::holds_alternative<flutter::EncodableMap>(arguments)) {
			return std::nullopt;
		}

		const auto& argumentsMap = std::get<flutter::EncodableMap>(arguments);
		const auto textIterator =
			argumentsMap.find(flutter::EncodableValue("text"));
		if (textIterator == argumentsMap.end() ||
			!std::holds_alternative<std::string>(textIterator->second)) {
			return std::nullopt;
		}

		std::optional<std::string> utteranceId;
		const auto utteranceIdIterator =
			argumentsMap.find(flutter::EncodableValue("utteranceId"));
		if (utteranceIdIterator != argumentsMap.end()) {
			if (!std::holds_alternative<std::string>(utteranceIdIterator->second)) {
				return std::nullopt;
			}
			const auto& value = std::get<std::string>(utteranceIdIterator->second);
			if (value.empty()) {
				return std::nullopt;
			}
			utteranceId = value;
		}

		return SpeakArguments{
			std::get<std::string>(textIterator->second), utteranceId};
	}

	std::unique_ptr<flutter::EncodableValue> speechEventArguments(
		const std::optional<std::string>& utteranceId) {
		if (!utteranceId) {
			return nullptr;
		}
		flutter::EncodableMap arguments;
		arguments[flutter::EncodableValue("utteranceId")] =
			flutter::EncodableValue(*utteranceId);
		return std::make_unique<flutter::EncodableValue>(std::move(arguments));
	}

	std::unique_ptr<flutter::EncodableValue> speechErrorArguments(
		const std::optional<std::string>& utteranceId,
		const std::string& message) {
		if (!utteranceId) {
			return std::make_unique<flutter::EncodableValue>(message);
		}
		flutter::EncodableMap arguments;
		arguments[flutter::EncodableValue("utteranceId")] =
			flutter::EncodableValue(*utteranceId);
		arguments[flutter::EncodableValue("message")] =
			flutter::EncodableValue(message);
		return std::make_unique<flutter::EncodableValue>(std::move(arguments));
	}

	flutter::EncodableValue acceptedSpeechResult(
		const std::optional<std::string>& utteranceId,
		const int value) {
		if (!utteranceId) {
			return flutter::EncodableValue(value);
		}
		flutter::EncodableMap result;
		result[flutter::EncodableValue("accepted")] =
			flutter::EncodableValue(true);
		result[flutter::EncodableValue("value")] =
			flutter::EncodableValue(value);
		return flutter::EncodableValue(std::move(result));
	}
}

#if defined(WINAPI_FAMILY) && (WINAPI_FAMILY == WINAPI_FAMILY_DESKTOP_APP)
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.Core.h>
using namespace winrt;
using namespace Windows::Media::SpeechSynthesis;
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
namespace {
	enum class WinRtSpeechEventType {
		SynthesisReady,
		PlaybackComplete,
		PlaybackError,
	};

	struct WinRtSpeechEvent {
		WinRtSpeechEventType type;
		uint64_t generation;
		std::optional<std::string> utteranceId;
		SpeechSynthesisStream stream{nullptr};
		std::string error;
	};

	using WinRtEventQueue = PlatformEventQueue<WinRtSpeechEvent>;

	class WinRtSpeechRequest {
	public:
		WinRtSpeechRequest(
			const uint64_t generation,
			std::optional<std::string> utteranceId,
			std::shared_ptr<WinRtEventQueue> eventQueue)
			: generation(generation),
			  utteranceId(std::move(utteranceId)),
			  eventQueue_(std::move(eventQueue)) {}

		bool AttachSynthesisOperation(
			winrt::Windows::Foundation::IAsyncOperation<
				SpeechSynthesisStream> operation) {
			bool cancelOperation = false;
			{
				std::lock_guard<std::mutex> lock(mutex_);
				if (cancelled_) {
					cancelOperation = true;
				} else {
					synthesisOperation_ = operation;
				}
			}
			if (cancelOperation) {
				try {
					operation.Cancel();
				} catch (...) {
				}
				return false;
			}
			return true;
		}

		void ClearSynthesisOperation() {
			std::lock_guard<std::mutex> lock(mutex_);
			synthesisOperation_ = nullptr;
		}

		bool Enqueue(WinRtSpeechEvent event) const {
			std::shared_ptr<WinRtEventQueue> eventQueue;
			{
				std::lock_guard<std::mutex> lock(mutex_);
				if (cancelled_) {
					return false;
				}
				eventQueue = eventQueue_;
			}
			return eventQueue->Enqueue(std::move(event));
		}

		bool IsCancelled() const {
			std::lock_guard<std::mutex> lock(mutex_);
			return cancelled_;
		}

		void Cancel() {
			winrt::Windows::Foundation::IAsyncOperation<
				SpeechSynthesisStream> operation{nullptr};
			{
				std::lock_guard<std::mutex> lock(mutex_);
				if (cancelled_) {
					return;
				}
				cancelled_ = true;
				operation = synthesisOperation_;
				synthesisOperation_ = nullptr;
			}
			if (operation) {
				try {
					operation.Cancel();
				} catch (...) {
				}
			}
		}

		const uint64_t generation;
		const std::optional<std::string> utteranceId;

	private:
		mutable std::mutex mutex_;
		bool cancelled_ = false;
		winrt::Windows::Foundation::IAsyncOperation<
			SpeechSynthesisStream> synthesisOperation_{nullptr};
		std::shared_ptr<WinRtEventQueue> eventQueue_;
	};

	winrt::fire_and_forget synthesizeSpeech(
		SpeechSynthesizer synthesizer,
		std::string text,
		std::shared_ptr<WinRtSpeechRequest> request) {
		try {
			auto operation =
				synthesizer.SynthesizeTextToStreamAsync(to_hstring(text));
			if (!request->AttachSynthesisOperation(operation)) {
				co_return;
			}
			SpeechSynthesisStream speechStream{co_await operation};
			request->ClearSynthesisOperation();
			request->Enqueue(WinRtSpeechEvent{
				WinRtSpeechEventType::SynthesisReady,
				request->generation,
				request->utteranceId,
				std::move(speechStream),
				{}});
		} catch (const winrt::hresult_error& error) {
			request->ClearSynthesisOperation();
			request->Enqueue(WinRtSpeechEvent{
				WinRtSpeechEventType::PlaybackError,
				request->generation,
				request->utteranceId,
				SpeechSynthesisStream{nullptr},
				to_string(error.message())});
		} catch (const std::exception& error) {
			request->ClearSynthesisOperation();
			request->Enqueue(WinRtSpeechEvent{
				WinRtSpeechEventType::PlaybackError,
				request->generation,
				request->utteranceId,
				SpeechSynthesisStream{nullptr},
				error.what()});
		} catch (...) {
			request->ClearSynthesisOperation();
			request->Enqueue(WinRtSpeechEvent{
				WinRtSpeechEventType::PlaybackError,
				request->generation,
				request->utteranceId,
				SpeechSynthesisStream{nullptr},
				"Error from Windows TextToSpeech"});
		}
	}

	class FlutterTtsPlugin : public flutter::Plugin {
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
		FlutterTtsPlugin(flutter::PluginRegistrarWindows* registrar);
		virtual ~FlutterTtsPlugin();
	private:
		// Called when a method is called on this plugin's channel from Dart.
		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
		void speak(const std::string, const std::optional<std::string>&, bool, FlutterResult);
		bool pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);
		bool isLanguageAvailable(const std::string);
		void addMplayer();
		void revokeMediaEventHandlers();
		void processAsyncEvents();
		void onSynthesisReady(const WinRtSpeechEvent&);
		void onSpeakComplete(uint64_t, const std::optional<std::string>&);
		void onSpeakError(uint64_t, const std::optional<std::string>&, const std::string& error);
		std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
		bool speaking();
		bool paused();
		SpeechSynthesizer synth;
		winrt::Windows::Media::Playback::MediaPlayer mPlayer;
		bool isPaused;
		bool isSpeaking;
		bool hasStartedPlayback;
		bool awaitSpeakCompletion;
		bool activeSpeakAwaitsCompletion;
		std::optional<std::string> activeUtteranceId;
		uint64_t requestGeneration;
		uint64_t activeRequestGeneration;
		winrt::event_token mediaEndedToken;
		winrt::event_token mediaFailedToken;
		bool hasMediaEndedHandler;
		bool hasMediaFailedHandler;
		std::shared_ptr<WinRtEventQueue> asyncEvents;
		std::shared_ptr<WinRtSpeechRequest> activeRequest;
		FlutterResult speakResult;
		std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel;
		flutter::PluginRegistrarWindows* registrar;
		int windowProcId;
	};

	void FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarWindows* registrar) {
		auto plugin = std::make_unique<FlutterTtsPlugin>(registrar);
		plugin->methodChannel =
			std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
				registrar->messenger(), "flutter_tts",
				&flutter::StandardMethodCodec::GetInstance());

		plugin->methodChannel->SetMethodCallHandler(
			[plugin_pointer = plugin.get()](const auto& call, auto result) {
			plugin_pointer->HandleMethodCall(call, std::move(result));
		});
		registrar->AddPlugin(std::move(plugin));
	}

	void FlutterTtsPlugin::addMplayer() {
		mPlayer = winrt::Windows::Media::Playback::MediaPlayer::MediaPlayer();
		hasMediaEndedHandler = false;
		hasMediaFailedHandler = false;
	}

	void FlutterTtsPlugin::revokeMediaEventHandlers() {
		if (hasMediaEndedHandler) {
			hasMediaEndedHandler = false;
			try {
				mPlayer.MediaEnded(mediaEndedToken);
			} catch (...) {
			}
		}
		if (hasMediaFailedHandler) {
			hasMediaFailedHandler = false;
			try {
				mPlayer.MediaFailed(mediaFailedToken);
			} catch (...) {
			}
		}
	}

	void FlutterTtsPlugin::processAsyncEvents() {
		for (const auto& event : asyncEvents->TakePending()) {
			switch (event.type) {
				case WinRtSpeechEventType::SynthesisReady:
					onSynthesisReady(event);
					break;
				case WinRtSpeechEventType::PlaybackComplete:
					onSpeakComplete(event.generation, event.utteranceId);
					break;
				case WinRtSpeechEventType::PlaybackError:
					onSpeakError(
						event.generation, event.utteranceId, event.error);
					break;
			}
		}
	}

	void FlutterTtsPlugin::onSynthesisReady(
		const WinRtSpeechEvent& event) {
		if (event.generation != activeRequestGeneration ||
			event.utteranceId != activeUtteranceId ||
			!activeRequest || activeRequest->IsCancelled()) {
			return;
		}

		try {
			winrt::param::hstring contentType = L"Audio";
			auto source = winrt::Windows::Media::Core::MediaSource::CreateFromStream(
				event.stream, contentType);
			revokeMediaEventHandlers();

			const std::weak_ptr<WinRtSpeechRequest> weakRequest =
				activeRequest;
			mediaEndedToken = mPlayer.MediaEnded(
				[weakRequest](
					Windows::Media::Playback::MediaPlayer const&,
					Windows::Foundation::IInspectable const&) {
					if (const auto request = weakRequest.lock()) {
						request->Enqueue(WinRtSpeechEvent{
							WinRtSpeechEventType::PlaybackComplete,
							request->generation,
							request->utteranceId,
							SpeechSynthesisStream{nullptr},
							{}});
					}
				});
			hasMediaEndedHandler = true;
			mediaFailedToken = mPlayer.MediaFailed(
				[weakRequest](
					Windows::Media::Playback::MediaPlayer const&,
					Windows::Media::Playback::MediaPlayerFailedEventArgs const& args) {
					if (const auto request = weakRequest.lock()) {
						std::string message = "Windows media playback failed";
						try {
							const auto nativeMessage = to_string(args.ErrorMessage());
							if (!nativeMessage.empty()) {
								message = nativeMessage;
							}
						} catch (...) {
						}
						request->Enqueue(WinRtSpeechEvent{
							WinRtSpeechEventType::PlaybackError,
							request->generation,
							request->utteranceId,
							SpeechSynthesisStream{nullptr},
							std::move(message)});
					}
				});
			hasMediaFailedHandler = true;

			mPlayer.Source(source);
			mPlayer.Play();
			hasStartedPlayback = true;
			methodChannel->InvokeMethod(
				"speak.onStart", speechEventArguments(event.utteranceId));
		} catch (const winrt::hresult_error& error) {
			onSpeakError(
				event.generation,
				event.utteranceId,
				to_string(error.message()));
		} catch (const std::exception& error) {
			onSpeakError(
				event.generation, event.utteranceId, error.what());
		} catch (...) {
			onSpeakError(
				event.generation,
				event.utteranceId,
				"Error starting Windows TextToSpeech playback");
		}
	}

	void FlutterTtsPlugin::onSpeakComplete(
		const uint64_t generation,
		const std::optional<std::string>& utteranceId) {
		if (generation != activeRequestGeneration ||
			utteranceId != activeUtteranceId) {
			return;
		}
		revokeMediaEventHandlers();
		methodChannel->InvokeMethod(
			"speak.onComplete", speechEventArguments(utteranceId));
		if (activeSpeakAwaitsCompletion && speakResult) {
			speakResult->Success(acceptedSpeechResult(utteranceId, 1));
			speakResult = FlutterResult();
		}
		isSpeaking = false;
		isPaused = false;
		hasStartedPlayback = false;
		activeSpeakAwaitsCompletion = false;
		activeUtteranceId.reset();
		activeRequestGeneration = 0;
		if (activeRequest) {
			activeRequest->Cancel();
			activeRequest.reset();
		}
	}

	void FlutterTtsPlugin::onSpeakError(
		const uint64_t generation,
		const std::optional<std::string>& utteranceId,
		const std::string& error) {
		if (generation != activeRequestGeneration ||
			utteranceId != activeUtteranceId) {
			return;
		}
		revokeMediaEventHandlers();
		methodChannel->InvokeMethod(
			"speak.onError",
			speechErrorArguments(utteranceId, error));
		if (activeSpeakAwaitsCompletion && speakResult) {
			speakResult->Success(acceptedSpeechResult(utteranceId, 0));
			speakResult = FlutterResult();
		}
		isSpeaking = false;
		isPaused = false;
		hasStartedPlayback = false;
		activeSpeakAwaitsCompletion = false;
		activeUtteranceId.reset();
		activeRequestGeneration = 0;
		if (activeRequest) {
			activeRequest->Cancel();
			activeRequest.reset();
		}
	}

	std::optional<LRESULT> FlutterTtsPlugin::HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
		if (!asyncEvents->HandlesMessage(message, wparam)) {
			return std::nullopt;
		}
		processAsyncEvents();
		return 0;
	}

	bool FlutterTtsPlugin::speaking() {
		return isSpeaking;
	}

	bool FlutterTtsPlugin::paused() {
		return isPaused;
	}

	void FlutterTtsPlugin::speak(
		const std::string text,
		const std::optional<std::string>& utteranceId,
		const bool awaitCompletion,
		FlutterResult result) {
		if (!asyncEvents->IsAvailable()) {
			result->Success(0);
			return;
		}
		activeUtteranceId = utteranceId;
		activeSpeakAwaitsCompletion = awaitCompletion;
		activeRequestGeneration = ++requestGeneration;
		const auto generation = activeRequestGeneration;
		activeRequest = std::make_shared<WinRtSpeechRequest>(
			generation, utteranceId, asyncEvents);
		isSpeaking = true;
		hasStartedPlayback = false;
		if (activeSpeakAwaitsCompletion) {
			speakResult = std::move(result);
		}
		if (!awaitCompletion) {
			result->Success(1);
		}
		synthesizeSpeech(synth, text, activeRequest);
	};

	bool FlutterTtsPlugin::pause() {
		if (isPaused) {
			return true;
		}
		if (!isSpeaking || !hasStartedPlayback) {
			return false;
		}
		mPlayer.Pause();
		isPaused = true;
		methodChannel->InvokeMethod(
			"speak.onPause", speechEventArguments(activeUtteranceId));
		return true;
	}

	void FlutterTtsPlugin::continuePlay() {
		mPlayer.Play();
		isPaused = false;
		methodChannel->InvokeMethod(
			"speak.onContinue", speechEventArguments(activeUtteranceId));
	}

	void FlutterTtsPlugin::stop() {
		const bool hadActiveSpeech = isSpeaking || isPaused || speakResult != nullptr;
		const auto utteranceId = activeUtteranceId;
		activeRequestGeneration = 0;
		++requestGeneration;
		if (activeRequest) {
			activeRequest->Cancel();
			activeRequest.reset();
		}
		if (hadActiveSpeech) {
			methodChannel->InvokeMethod(
				"speak.onCancel", speechEventArguments(utteranceId));
		}
		if (activeSpeakAwaitsCompletion && speakResult) {
			speakResult->Success(acceptedSpeechResult(utteranceId, 0));
			speakResult = FlutterResult();
		}

		isSpeaking = false;
		isPaused = false;
		hasStartedPlayback = false;
		activeSpeakAwaitsCompletion = false;
		activeUtteranceId.reset();
		revokeMediaEventHandlers();
		mPlayer.Close();
		addMplayer();
	}
	void FlutterTtsPlugin::setVolume(const double newVolume) { synth.Options().AudioVolume(newVolume); }

	void FlutterTtsPlugin::setPitch(const double newPitch) { synth.Options().AudioPitch(newPitch); }

	void FlutterTtsPlugin::setRate(const double newRate) { synth.Options().SpeakingRate(newRate + 0.5); }

	void FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {
		auto synthVoices = synth.AllVoices();
		std::for_each(begin(synthVoices), end(synthVoices), [&voices](const VoiceInformation& voice)
			{
				flutter::EncodableMap voiceInfo;
				voiceInfo[flutter::EncodableValue("locale")] = to_string(voice.Language());
				voiceInfo[flutter::EncodableValue("name")] = to_string(voice.DisplayName());
				//  Convert VoiceGender to string
				std::string gender;
				switch (voice.Gender()) {
					case VoiceGender::Male:
						gender = "male";
						break;
					case VoiceGender::Female:
						gender = "female";
						break;
					default:
						gender = "unknown";
						break;
				}
				voiceInfo[flutter::EncodableValue("gender")] = gender; 
				// Identifier example "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_enUS_MarkM"
				voiceInfo[flutter::EncodableValue("identifier")] = to_string(voice.Id());
				voices.push_back(flutter::EncodableMap(voiceInfo));
			});
	}

	void FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {
		bool found = false;
		auto voices = synth.AllVoices();
		VoiceInformation newVoice = synth.Voice();
		std::for_each(begin(voices), end(voices), [&voiceLanguage, &voiceName, &found, &newVoice](const VoiceInformation& voice)
			{
				if (to_string(voice.Language()) == voiceLanguage && to_string(voice.DisplayName()) == voiceName)
				{
					newVoice = voice;
					found = true;
				}
			});
		synth.Voice(newVoice);
		if (found) result->Success(1);
		else result->Success(0);
	}

	void FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages) {
		auto synthVoices = synth.AllVoices();
		std::set<flutter::EncodableValue> languagesSet = {};
		std::for_each(begin(synthVoices), end(synthVoices), [&languagesSet](const VoiceInformation& voice)
			{
				languagesSet.insert(flutter::EncodableValue(to_string(voice.Language())));
			});
		std::for_each(begin(languagesSet), end(languagesSet), [&languages](const flutter::EncodableValue value)
			{
				languages.push_back(value);
			});
	}
	void FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {
		bool found = false;
		auto voices = synth.AllVoices();
		VoiceInformation newVoice = synth.Voice();
		std::for_each(begin(voices), end(voices), [&voiceLanguage, &newVoice, &found](const VoiceInformation& voice)
			{
				if (to_string(voice.Language()) == voiceLanguage) {
					newVoice = voice;
					found = true;
				}
			});
		if (found) {
			synth.Voice(newVoice);
			result->Success(1);
		}
		else {
			result->Success(0);
		}
	}

	bool FlutterTtsPlugin::isLanguageAvailable(const std::string voiceLanguage) {
		auto voices = synth.AllVoices();
		for (const VoiceInformation& voice : voices) {
			if (to_string(voice.Language()) == voiceLanguage) {
				return true;
			}
		}
		return false;
	}


	FlutterTtsPlugin::FlutterTtsPlugin(flutter::PluginRegistrarWindows* registrar) : registrar(registrar) {
		synth = SpeechSynthesizer();
		addMplayer();
		isPaused = false;
		isSpeaking = false;
		hasStartedPlayback = false;
		awaitSpeakCompletion = false;
		activeSpeakAwaitsCompletion = false;
		requestGeneration = 0;
		activeRequestGeneration = 0;
		speakResult = FlutterResult();
		const auto* view = registrar->GetView();
		const HWND viewWindow =
			view != nullptr ? view->GetNativeWindow() : nullptr;
		asyncEvents = std::make_shared<WinRtEventQueue>(viewWindow);
		// Register the raw-this callback only after every potentially throwing
		// initialization step has completed. A failed constructor does not run the
		// destructor, so registering earlier could leave the registrar with a
		// dangling delegate.
		windowProcId = registrar->RegisterTopLevelWindowProcDelegate(
			[this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
				return HandleWindowProc(hwnd, message, wparam, lparam);
			});
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() {
		activeRequestGeneration = 0;
		++requestGeneration;
		if (activeRequest) {
			activeRequest->Cancel();
			activeRequest.reset();
		}
		asyncEvents->Shutdown();
		revokeMediaEventHandlers();
		registrar->UnregisterTopLevelWindowProcDelegate(windowProcId);
		if (methodChannel) {
			methodChannel->SetMethodCallHandler(nullptr);
		}
		speakResult = FlutterResult();
		try {
			mPlayer.Close();
		} catch (...) {
		}
	}

	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {
		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows";
			result->Success(flutter::EncodableValue(version_stream.str()));
		}

#else
#include <string>
#include <atlbase.h>
#include <atlstr.h>
#include <array>
#include <sapi.h>
#pragma warning(disable:4996)
#include <sphelper.h>
#pragma warning(default: 4996)
namespace {
	struct SapiSpeechEvent {
		uint64_t generation;
		std::optional<std::string> utteranceId;
	};

	using SapiEventQueue = PlatformEventQueue<SapiSpeechEvent>;

	class FlutterTtsPlugin : public flutter::Plugin {
	public:
		static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
		FlutterTtsPlugin(flutter::PluginRegistrarWindows* registrar);
		virtual ~FlutterTtsPlugin();
	private:
		// Called when a method is called on this plugin's channel from Dart.
		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

		void speak(const std::string, const std::optional<std::string>&, bool, FlutterResult);
		bool pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);
		bool isLanguageAvailable(const std::string);
		struct CompletionContext {
			std::shared_ptr<SapiEventQueue> asyncEvents;
			uint64_t generation;
			std::optional<std::string> utteranceId;
		};
		static void CALLBACK onCompletion(PVOID, BOOLEAN);
		void clearCompletionWait();
		void processAsyncEvents();
		void onSpeakComplete(uint64_t, const std::optional<std::string>&);
		void completePendingSpeak(const int);
		std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

		ISpVoice* pVoice;
		bool awaitSpeakCompletion = false;
		bool activeSpeakAwaitsCompletion;
		std::optional<std::string> activeUtteranceId;
		uint64_t requestGeneration;
		uint64_t activeRequestGeneration;
		bool isPaused;
		double pitch;
		bool speaking();
		bool paused();
		FlutterResult speakResult;
		std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel;
		HANDLE addWaitHandle;
		CompletionContext* completionContext;
		std::shared_ptr<SapiEventQueue> asyncEvents;
		flutter::PluginRegistrarWindows* registrar;
		int windowProcId;
	};

	void FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarWindows* registrar) {
		auto plugin = std::make_unique<FlutterTtsPlugin>(registrar);
		plugin->methodChannel =
			std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
				registrar->messenger(), "flutter_tts",
				&flutter::StandardMethodCodec::GetInstance());
		plugin->methodChannel->SetMethodCallHandler(
			[plugin_pointer = plugin.get()](const auto& call, auto result) {
			plugin_pointer->HandleMethodCall(call, std::move(result));
		});

		registrar->AddPlugin(std::move(plugin));
	}

	FlutterTtsPlugin::FlutterTtsPlugin(flutter::PluginRegistrarWindows* registrar) : registrar(registrar) {
		addWaitHandle = NULL;
		completionContext = nullptr;
		isPaused = false;
		activeSpeakAwaitsCompletion = false;
		requestGeneration = 0;
		activeRequestGeneration = 0;
		speakResult = NULL;
		pVoice = NULL;
		pitch = 1.0;
		const auto* view = registrar->GetView();
		const HWND viewWindow =
			view != nullptr ? view->GetNativeWindow() : nullptr;
		asyncEvents = std::make_shared<SapiEventQueue>(viewWindow);

		HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
		if (FAILED(hr))
		{
			throw std::exception("TTS init failed");
		}

		try {
			hr = CoCreateInstance(CLSID_SpVoice, NULL, CLSCTX_ALL, IID_ISpVoice, (void**)&pVoice);
			if (FAILED(hr))
			{
				throw std::exception("TTS create instance failed");
			}

			// Keep the raw-this callback as the final initialization step. If COM or
			// voice creation fails, no registrar callback can outlive this object.
			windowProcId = registrar->RegisterTopLevelWindowProcDelegate(
				[this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
					return HandleWindowProc(hwnd, message, wparam, lparam);
				});
		} catch (...) {
			if (pVoice != NULL) {
				pVoice->Release();
				pVoice = NULL;
			}
			::CoUninitialize();
			throw;
		}
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() {
		activeRequestGeneration = 0;
		++requestGeneration;
		asyncEvents->Shutdown();
		clearCompletionWait();
		if (pVoice != NULL) {
			pVoice->Release();
			pVoice = NULL;
		}
		registrar->UnregisterTopLevelWindowProcDelegate(windowProcId);
		if (methodChannel) {
			methodChannel->SetMethodCallHandler(nullptr);
		}
		speakResult = FlutterResult();
		::CoUninitialize();
	}

	void CALLBACK FlutterTtsPlugin::onCompletion(
		PVOID contextPointer,
		BOOLEAN) {
		auto* context = static_cast<CompletionContext*>(contextPointer);
		context->asyncEvents->Enqueue(SapiSpeechEvent{
			context->generation, context->utteranceId});
	}

	void FlutterTtsPlugin::clearCompletionWait() {
		if (addWaitHandle != NULL) {
			UnregisterWaitEx(addWaitHandle, INVALID_HANDLE_VALUE);
			addWaitHandle = NULL;
		}
		delete completionContext;
		completionContext = nullptr;
	}

	std::string escapeSapiXml(const std::string& text) {
		std::string escaped;
		escaped.reserve(text.size());
		for (char c : text) {
			switch (c) {
				case '&':
					escaped.append("&amp;");
					break;
				case '<':
					escaped.append("&lt;");
					break;
				case '>':
					escaped.append("&gt;");
					break;
				case '"':
					escaped.append("&quot;");
					break;
				case '\'':
					escaped.append("&apos;");
					break;
				default:
					escaped.push_back(c);
					break;
			}
		}
		return escaped;
	}

	void FlutterTtsPlugin::completePendingSpeak(const int success) {
		if (activeSpeakAwaitsCompletion && speakResult) {
			speakResult->Success(
				acceptedSpeechResult(activeUtteranceId, success));
			speakResult = NULL;
		}
		activeSpeakAwaitsCompletion = false;
	}

	void FlutterTtsPlugin::processAsyncEvents() {
		for (const auto& event : asyncEvents->TakePending()) {
			onSpeakComplete(event.generation, event.utteranceId);
		}
	}

	std::optional<LRESULT> FlutterTtsPlugin::HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
		if (!asyncEvents->HandlesMessage(message, wparam)) {
			return std::nullopt;
		}
		processAsyncEvents();
		return 0;
	}

	void FlutterTtsPlugin::onSpeakComplete(
		const uint64_t generation,
		const std::optional<std::string>& utteranceId) {
		if (generation != activeRequestGeneration ||
			utteranceId != activeUtteranceId) {
			return;
		}
		methodChannel->InvokeMethod(
			"speak.onComplete", speechEventArguments(utteranceId));
		completePendingSpeak(1);
		activeUtteranceId.reset();
		activeRequestGeneration = 0;
		clearCompletionWait();
	}

	bool FlutterTtsPlugin::speaking()
	{
		if (pVoice == NULL) {
			return false;
		}
		SPVOICESTATUS status{};
		const HRESULT hr = pVoice->GetStatus(&status, NULL);
		return SUCCEEDED(hr) && status.dwRunningState == SPRS_IS_SPEAKING;
	}
	bool FlutterTtsPlugin::paused() { return isPaused; }


	void FlutterTtsPlugin::speak(
		const std::string text,
		const std::optional<std::string>& utteranceId,
		const bool awaitCompletion,
		FlutterResult result) {
		if (!asyncEvents->IsAvailable()) {
			result->Success(0);
			return;
		}
		clearCompletionWait();
		activeUtteranceId = utteranceId;
		activeSpeakAwaitsCompletion = awaitCompletion;
		activeRequestGeneration = ++requestGeneration;
		const auto generation = activeRequestGeneration;
		HRESULT hr;
		const std::string arg = "<PITCH MIDDLE = '" + std::to_string(int((pitch - 1) * 10 * (1 + (pitch < 1)) )) + "'/>" + escapeSapiXml(text);

		int wchars_num = MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, NULL, 0);
		if (wchars_num <= 0) {
			methodChannel->InvokeMethod(
				"speak.onError",
				speechErrorArguments(
					activeUtteranceId, "Could not encode SAPI speech text"));
			result->Success(0);
			activeSpeakAwaitsCompletion = false;
			activeUtteranceId.reset();
			activeRequestGeneration = 0;
			return;
		}
		wchar_t* wstr = new wchar_t[wchars_num];
		MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, wstr, wchars_num);
		hr = pVoice->Speak(wstr, 1, NULL);
		delete[] wstr;
		if (FAILED(hr)) {
			const std::string error = "Error from SAPI TextToSpeech";
			methodChannel->InvokeMethod(
				"speak.onError",
				speechErrorArguments(activeUtteranceId, error));
			result->Success(0);
			activeSpeakAwaitsCompletion = false;
			activeUtteranceId.reset();
			activeRequestGeneration = 0;
			return;
		}
		HANDLE speakCompletionHandle = pVoice->SpeakCompleteEvent();
		if (activeSpeakAwaitsCompletion) {
			speakResult = std::move(result);
		}
		completionContext =
			new CompletionContext{asyncEvents, generation, activeUtteranceId};
		methodChannel->InvokeMethod(
			"speak.onStart", speechEventArguments(activeUtteranceId));
		if (!RegisterWaitForSingleObject(
			&addWaitHandle,
			speakCompletionHandle,
			&FlutterTtsPlugin::onCompletion,
			completionContext,
			INFINITE,
			WT_EXECUTEONLYONCE)) {
			const std::string error = "Could not monitor SAPI speech completion";
			pVoice->Speak(L"", 2, NULL);
			methodChannel->InvokeMethod(
				"speak.onError",
				speechErrorArguments(activeUtteranceId, error));
			if (activeSpeakAwaitsCompletion) {
				completePendingSpeak(0);
			} else {
				result->Success(0);
			}
			clearCompletionWait();
			activeUtteranceId.reset();
			activeRequestGeneration = 0;
			return;
		}
		if (!awaitCompletion) {
			result->Success(1);
		}
	}
	bool FlutterTtsPlugin::pause()
	{
		if (isPaused) {
			return true;
		}
		if (!speaking()) {
			return false;
		}
		const HRESULT hr = pVoice->Pause();
		if (FAILED(hr)) {
			return false;
		}
		isPaused = true;
		methodChannel->InvokeMethod(
			"speak.onPause", speechEventArguments(activeUtteranceId));
		return true;
	}
	void FlutterTtsPlugin::continuePlay()
	{
		isPaused = false;
		pVoice->Resume();
		methodChannel->InvokeMethod(
			"speak.onContinue", speechEventArguments(activeUtteranceId));
	}
	void FlutterTtsPlugin::stop()
	{
		const bool hadActiveSpeech = activeRequestGeneration != 0 ||
			speaking() || isPaused || addWaitHandle != NULL || speakResult != NULL;
		const auto utteranceId = activeUtteranceId;
		activeRequestGeneration = 0;
		++requestGeneration;
		completePendingSpeak(0);
		clearCompletionWait();
		pVoice->Speak(L"", 2, NULL);
		pVoice->Resume();
		isPaused = false;
		if (hadActiveSpeech) {
			methodChannel->InvokeMethod(
				"speak.onCancel", speechEventArguments(utteranceId));
		}
		activeUtteranceId.reset();
	}
	void FlutterTtsPlugin::setVolume(const double newVolume)
	{
		const USHORT volume = (short)(100 * newVolume);
		pVoice->SetVolume(volume);
	}
	void FlutterTtsPlugin::setPitch(const double newPitch) {pitch = newPitch;}
	void FlutterTtsPlugin::setRate(const double newRate)
	{
		const long speechRate = (long)((newRate - 0.5) * 15);
		pVoice->SetRate(speechRate);
	}
	void FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) return;

 		ULONG ulCount = 0;
		// Get the number of voices.
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) return;
		while (ulCount--)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) return;
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) return;
			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
			if (FAILED(hr)) return;
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(CW2A(psz), NULL, 16), locale, 25, 0);
            ::CoTaskMemFree(psz);
            std::string language = CW2A(locale);
            psz = NULL;
            hr = cpAttribKey->GetStringValue(L"Name", &psz);
			if (FAILED(hr)) return;
			std::string name = CW2A(psz);
			::CoTaskMemFree(psz);
            flutter::EncodableMap voiceInfo;
            voiceInfo[flutter::EncodableValue("locale")] = language;
            voiceInfo[flutter::EncodableValue("name")] = name;
            voices.push_back(flutter::EncodableMap(voiceInfo));
		}
	}
	void FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) { result->Success(0); return; }
		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) { result->Success(0); return; }
		bool success = false;
		while (ulCount--)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) { result->Success(0); return; }
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) { result->Success(0); return; }
			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Name", &psz);
			if (FAILED(hr)) { result->Success(0); return; }
			std::string name = CW2A(psz);
			::CoTaskMemFree(psz);
			psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
			if (FAILED(hr)) { result->Success(0); return; }
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(CW2A(psz), NULL, 16), locale, 25, 0);
            ::CoTaskMemFree(psz);
            std::string language = CW2A(locale);
			if (name == voiceName && language == voiceLanguage)
			{
				pVoice->SetVoice(cpVoiceToken);
				success = true;
			}
		}
		result->Success(success ? 1 : 0);
	}
	void FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages)
	{
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) return;

 		ULONG ulCount = 0;
		// Get the number of voices.
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) return;
        std::set<flutter::EncodableValue> languagesSet = {};
		while (ulCount--)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) return;
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) return;

			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
			if (FAILED(hr)) return;
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(CW2A(psz), NULL, 16), locale, 25, 0);
            std::string language = CW2A(locale);
			languagesSet.insert(flutter::EncodableValue(language));
			::CoTaskMemFree(psz);
		}
        std::for_each(begin(languagesSet), end(languagesSet), [&languages](const flutter::EncodableValue value)
            {
                languages.push_back(value);
            });
	}

	void FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) { result->Success(0); return; }
		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) { result->Success(0); return; }
		bool found = false;
		while (ulCount--)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) { result->Success(0); return; }
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) { result->Success(0); return; }

			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
			if (FAILED(hr)) { result->Success(0); return; }
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(CW2A(psz), NULL, 16), locale, 25, 0);
            std::string language = CW2A(locale);
			if (language == voiceLanguage)
			{
				pVoice->SetVoice(cpVoiceToken);
				found = true;
			}
			::CoTaskMemFree(psz);
		}
		if (found) result->Success(1);
		else result->Success(0);
	}

	bool FlutterTtsPlugin::isLanguageAvailable(const std::string voiceLanguage) {
		HRESULT hr;
		CComPtr<IEnumSpObjectTokens> cpEnum;
		hr = SpEnumTokens(SPCAT_VOICES, NULL, NULL, &cpEnum);
		if (FAILED(hr)) return false;
		ULONG ulCount = 0;
		hr = cpEnum->GetCount(&ulCount);
		if (FAILED(hr)) return false;
		while (ulCount--)
		{
			CComPtr<ISpObjectToken> cpVoiceToken;
			hr = cpEnum->Next(1, &cpVoiceToken, NULL);
			if (FAILED(hr)) return false;
			CComPtr<ISpDataKey> cpAttribKey;
			hr = cpVoiceToken->OpenKey(L"Attributes", &cpAttribKey);
			if (FAILED(hr)) return false;

			WCHAR* psz = NULL;
			hr = cpAttribKey->GetStringValue(L"Language", &psz);
			if (FAILED(hr)) return false;
		    wchar_t locale[25];
            LCIDToLocaleName((LCID)std::strtol(CW2A(psz), NULL, 16), locale, 25, 0);
            std::string language = CW2A(locale);
			::CoTaskMemFree(psz);
			if (language == voiceLanguage)
			{
				return true;
			}
		}
		return false;
	}


	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {

		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows ";
			if (IsWindows10OrGreater()) {
				version_stream << "10+";
			}
			else if (IsWindows8OrGreater()) {
				version_stream << "8";
			}
			else if (IsWindows7OrGreater()) {
				version_stream << "7";
			}
			result->Success(flutter::EncodableValue(version_stream.str()));
		}
#endif
		else if (method_call.method_name().compare("awaitSpeakCompletion") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<bool>(arg)) {
                awaitSpeakCompletion = std::get<bool>(arg);
                result->Success(1);
            }
            else result->Success(0);
        }
		else if (method_call.method_name().compare("speak") == 0) {
			const auto* rawArguments = method_call.arguments();
			if (rawArguments == nullptr) {
				result->Success(0);
				return;
			}
			const auto arguments = parseSpeakArguments(*rawArguments);
			if (!arguments) {
				result->Success(0);
				return;
			}
			if (isPaused) {
				const bool sameUtterance =
					arguments->utteranceId == activeUtteranceId;
				if (!sameUtterance) {
					result->Success(0);
					return;
				}
				continuePlay();
				result->Success(1);
				return;
			}
			if (!speaking() && activeRequestGeneration == 0) {
				speak(arguments->text, arguments->utteranceId,
					awaitSpeakCompletion, std::move(result));
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("pause") == 0) {
			result->Success(FlutterTtsPlugin::pause() ? 1 : 0);
		}
		else if (method_call.method_name().compare("setLanguage") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				const std::string lang = std::get<std::string>(arg);
				setLanguage(lang, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("isLanguageAvailable") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				const std::string lang = std::get<std::string>(arg);
				result->Success(isLanguageAvailable(lang));
			}
			else result->Success(false);
		}
		else if (method_call.method_name().compare("setVolume") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newVolume = std::get<double>(arg);
				if (newVolume < 0.0 || newVolume > 1.0) {
					result->Success(0);
					return;
				}
				setVolume(newVolume);
				result->Success(1);
			}
			else result->Success(0);

		}
		else if (method_call.method_name().compare("setSpeechRate") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newRate = std::get<double>(arg);
				if (newRate < 0.0 || newRate > 1.0) {
					result->Success(0);
					return;
				}
				setRate(newRate);
				result->Success(1);
			}
			else result->Success(0);

		}
        else if (method_call.method_name().compare("setPitch") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<double>(arg)) {
                const double newPitch = std::get<double>(arg);
                if (newPitch < 0.5 || newPitch > 2.0) {
                    result->Success(0);
                    return;
                }
                setPitch(newPitch);
                result->Success(1);
            }
            else result->Success(0);
        }
		else if (method_call.method_name().compare("setVoice") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<flutter::EncodableMap>(arg)) {
				const flutter::EncodableMap voiceInfo = std::get<flutter::EncodableMap>(arg);
				std::string voiceLanguage = "";
				std::string voiceName = "";
				auto voiceLanguage_it = voiceInfo.find(flutter::EncodableValue("locale"));
				if (voiceLanguage_it != voiceInfo.end()) voiceLanguage = std::get<std::string>(voiceLanguage_it->second);
				auto voiceName_it = voiceInfo.find(flutter::EncodableValue("name"));
				if (voiceName_it != voiceInfo.end()) voiceName = std::get<std::string>(voiceName_it->second);
				setVoice(voiceLanguage, voiceName, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("stop") == 0) {
			stop();
			result->Success(1);
		}
		else if (method_call.method_name().compare("getLanguages") == 0) {
			flutter::EncodableList l;
			getLanguages(l);
			result->Success(l);
		}
		else if (method_call.method_name().compare("getVoices") == 0) {
			flutter::EncodableList l;
			getVoices(l);
			result->Success(l);
		}
		else {
			result->NotImplemented();
		}
	}
}

void FlutterTtsPluginRegisterWithRegistrar(
	FlutterDesktopPluginRegistrarRef registrar) {
	FlutterTtsPlugin::RegisterWithRegistrar(
		flutter::PluginRegistrarManager::GetInstance()
		->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
