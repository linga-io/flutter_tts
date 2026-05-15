#include "include/flutter_tts/flutter_tts_plugin.h"
// This must be included before many other Windows headers.
#include <windows.h>
#include <ppltasks.h>
#include <VersionHelpers.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <memory>
#include <optional>
#include <sstream>

typedef std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> FlutterResult;
//typedef flutter::MethodResult<flutter::EncodableValue>* PFlutterResult;

constexpr UINT kFlutterTtsSpeakCompleteMessage = WM_APP + 0x3D7;

#if defined(WINAPI_FAMILY) && (WINAPI_FAMILY == WINAPI_FAMILY_DESKTOP_APP)
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.Core.h>
using namespace winrt;
using namespace Windows::Media::SpeechSynthesis;
using namespace Concurrency;
using namespace std::chrono_literals;
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
namespace {
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
		void speak(const std::string, FlutterResult);
		void pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);
		void addMplayer();
		void onSpeakComplete();
		void postSpeakComplete();
		std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
		winrt::Windows::Foundation::IAsyncAction asyncSpeak(const std::string);
		bool speaking();
		bool paused();
		SpeechSynthesizer synth;
		winrt::Windows::Media::Playback::MediaPlayer mPlayer;
		bool isPaused;
		bool isSpeaking;
		bool awaitSpeakCompletion;
		FlutterResult speakResult;
		std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel;
		flutter::PluginRegistrarWindows* registrar;
		HWND windowHandle;
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
		auto mEndedToken =
			mPlayer.MediaEnded([=](Windows::Media::Playback::MediaPlayer const& sender,
				Windows::Foundation::IInspectable const& args)
				{
				    postSpeakComplete();
				});
	}

	void FlutterTtsPlugin::onSpeakComplete() {
		methodChannel->InvokeMethod("speak.onComplete", NULL);
		if (awaitSpeakCompletion && speakResult) {
			speakResult->Success(1);
			speakResult = FlutterResult();
		}
		isSpeaking = false;
	}

	void FlutterTtsPlugin::postSpeakComplete() {
		if (windowHandle != nullptr) {
			PostMessage(windowHandle, kFlutterTtsSpeakCompleteMessage, 0, 0);
		} else {
			onSpeakComplete();
		}
	}

	std::optional<LRESULT> FlutterTtsPlugin::HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
		if (message == kFlutterTtsSpeakCompleteMessage) {
			onSpeakComplete();
			return 0;
		}
		return std::nullopt;
	}

	bool FlutterTtsPlugin::speaking() {
		return isSpeaking;
	}

	bool FlutterTtsPlugin::paused() {
		return isPaused;
	}

	winrt::Windows::Foundation::IAsyncAction FlutterTtsPlugin::asyncSpeak(const std::string text) {
		SpeechSynthesisStream speechStream{
		  co_await synth.SynthesizeTextToStreamAsync(to_hstring(text))
		};
		winrt::param::hstring cType = L"Audio";
		winrt::Windows::Media::Core::MediaSource source =
			winrt::Windows::Media::Core::MediaSource::CreateFromStream(speechStream, cType);
		mPlayer.Source(source);
		mPlayer.Play();
	}

	void FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {
		isSpeaking = true;
		auto my_task{ asyncSpeak(text) };
		methodChannel->InvokeMethod("speak.onStart", NULL);
        if (awaitSpeakCompletion) speakResult = std::move(result);
        else result->Success(1);
	};

	void FlutterTtsPlugin::pause() {
		mPlayer.Pause();
		isPaused = true;
		methodChannel->InvokeMethod("speak.onPause", NULL);
	}

	void FlutterTtsPlugin::continuePlay() {
		mPlayer.Play();
		isPaused = false;
		methodChannel->InvokeMethod("speak.onContinue", NULL);
	}

	void FlutterTtsPlugin::stop() {
	    methodChannel->InvokeMethod("speak.onCancel", NULL);
        if (awaitSpeakCompletion && speakResult) {
            speakResult->Success(0);
			speakResult = FlutterResult();
        }

		mPlayer.Close();
		addMplayer();
		isSpeaking = false;
		isPaused = false;
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


	FlutterTtsPlugin::FlutterTtsPlugin(flutter::PluginRegistrarWindows* registrar) : registrar(registrar) {
		synth = SpeechSynthesizer();
		windowHandle = registrar->GetView() ? registrar->GetView()->GetNativeWindow() : nullptr;
		windowProcId = registrar->RegisterTopLevelWindowProcDelegate(
			[this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
				return HandleWindowProc(hwnd, message, wparam, lparam);
			});
		addMplayer();
		isPaused = false;
		isSpeaking = false;
		awaitSpeakCompletion = false;
		speakResult = FlutterResult();
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() {
		registrar->UnregisterTopLevelWindowProcDelegate(windowProcId);
		mPlayer.Close();
	}

	void FlutterTtsPlugin::HandleMethodCall(
		const flutter::MethodCall<flutter::EncodableValue>& method_call,
		FlutterResult result) {
		if (method_call.method_name().compare("getPlatformVersion") == 0) {
			std::ostringstream version_stream;
			version_stream << "Windows UWP";
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

		void speak(const std::string, FlutterResult);
		void pause();
		void continuePlay();
		void stop();
		void setVolume(const double);
		void setPitch(const double);
		void setRate(const double);
		void getVoices(flutter::EncodableList&);
		void setVoice(const std::string, const std::string, FlutterResult&);
		void getLanguages(flutter::EncodableList&);
		void setLanguage(const std::string, FlutterResult&);
		void onSpeakComplete();
		void completePendingSpeak(const int);
		void postSpeakComplete();
		std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

		ISpVoice* pVoice;
		bool awaitSpeakCompletion = false;
		bool isPaused;
		bool suppressNextCompletion;
		double pitch;
		bool speaking();
		bool paused();
		FlutterResult speakResult;
		std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel;
    	HANDLE addWaitHandle;
		flutter::PluginRegistrarWindows* registrar;
		HWND windowHandle;
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
		windowHandle = registrar->GetView() ? registrar->GetView()->GetNativeWindow() : nullptr;
		windowProcId = registrar->RegisterTopLevelWindowProcDelegate(
			[this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
				return HandleWindowProc(hwnd, message, wparam, lparam);
			});
		isPaused = false;
		suppressNextCompletion = false;
		speakResult = NULL;
		pVoice = NULL;
		HRESULT hr;
		hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
		if (FAILED(hr))
		{
			throw std::exception("TTS init failed");
		}

		hr = CoCreateInstance(CLSID_SpVoice, NULL, CLSCTX_ALL, IID_ISpVoice, (void**)&pVoice);
		if (FAILED(hr))
		{
			throw std::exception("TTS create instance failed");
		}
		pitch = 0;
	}

	FlutterTtsPlugin::~FlutterTtsPlugin() {
		if (addWaitHandle != NULL) {
			UnregisterWaitEx(addWaitHandle, INVALID_HANDLE_VALUE);
			addWaitHandle = NULL;
		}
		if (pVoice != NULL) {
			pVoice->Release();
			pVoice = NULL;
		}
		registrar->UnregisterTopLevelWindowProcDelegate(windowProcId);
		::CoUninitialize();
	}

	void CALLBACK onCompletion(PVOID lpParam, BOOLEAN TimerOrWaitFired)
    {
        FlutterTtsPlugin* plugin = static_cast<FlutterTtsPlugin*>(lpParam);
        plugin->postSpeakComplete();
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
		if (awaitSpeakCompletion && speakResult) {
			speakResult->Success(success);
			speakResult = NULL;
		}
	}

	void FlutterTtsPlugin::postSpeakComplete() {
		if (windowHandle != nullptr) {
			PostMessage(windowHandle, kFlutterTtsSpeakCompleteMessage, 0, 0);
		} else {
			onSpeakComplete();
		}
	}

	std::optional<LRESULT> FlutterTtsPlugin::HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
		if (message == kFlutterTtsSpeakCompleteMessage) {
			onSpeakComplete();
			return 0;
		}
		return std::nullopt;
	}

	void FlutterTtsPlugin::onSpeakComplete() {
		if (suppressNextCompletion) {
			suppressNextCompletion = false;
			if (addWaitHandle != NULL) {
				UnregisterWaitEx(addWaitHandle, NULL);
				addWaitHandle = NULL;
			}
			return;
		}
		methodChannel->InvokeMethod("speak.onComplete", NULL);
		completePendingSpeak(1);
		if (addWaitHandle != NULL) {
			UnregisterWaitEx(addWaitHandle, NULL);
			addWaitHandle = NULL;
		}
	}

	bool FlutterTtsPlugin::speaking()
	{
		SPVOICESTATUS status;
		pVoice->GetStatus(&status, NULL);
		if (status.dwRunningState == SPRS_IS_SPEAKING) return true;
		return false;
	}
	bool FlutterTtsPlugin::paused() { return isPaused; }


	void FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {
		HRESULT hr;
		const std::string arg = "<PITCH MIDDLE = '" + std::to_string(int((pitch - 1) * 10 * (1 + (pitch < 1)) )) + "'/>" + escapeSapiXml(text);

		int wchars_num = MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, NULL, 0);
		wchar_t* wstr = new wchar_t[wchars_num];
		MultiByteToWideChar(CP_UTF8, 0, arg.c_str(), -1, wstr, wchars_num);
		hr = pVoice->Speak(wstr, 1, NULL);
		delete[] wstr;
		HANDLE speakCompletionHandle = pVoice->SpeakCompleteEvent();
		methodChannel->InvokeMethod("speak.onStart", NULL);
		if (awaitSpeakCompletion){
		    speakResult = std::move(result);
		}
		else result->Success(1);
		RegisterWaitForSingleObject(&addWaitHandle, speakCompletionHandle, (WAITORTIMERCALLBACK)&onCompletion, this, INFINITE, WT_EXECUTEONLYONCE);
	}
	void FlutterTtsPlugin::pause()
	{
		if (isPaused == false)
		{
			pVoice->Pause();
			isPaused = true;
		}
	    methodChannel->InvokeMethod("speak.onPause", NULL);
	}
	void FlutterTtsPlugin::continuePlay()
	{
		isPaused = false;
		pVoice->Resume();
	    methodChannel->InvokeMethod("speak.onContinue", NULL);
	}
	void FlutterTtsPlugin::stop()
	{
		suppressNextCompletion = true;
		completePendingSpeak(0);
		pVoice->Speak(L"", 2, NULL);
		pVoice->Resume();
		isPaused = false;
	    methodChannel->InvokeMethod("speak.onCancel", NULL);
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
			if (isPaused) { continuePlay(); result->Success(1); return; }
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				if (!speaking()) {
					const std::string text = std::get<std::string>(arg);
					speak(text, std::move(result));
				}
				else result->Success(0);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("pause") == 0) {
			FlutterTtsPlugin::pause();
			result->Success(1);
		}
		else if (method_call.method_name().compare("setLanguage") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<std::string>(arg)) {
				const std::string lang = std::get<std::string>(arg);
				setLanguage(lang, result);
			}
			else result->Success(0);
		}
		else if (method_call.method_name().compare("setVolume") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newVolume = std::get<double>(arg);
				setVolume(newVolume);
				result->Success(1);
			}
			else result->Success(0);

		}
		else if (method_call.method_name().compare("setSpeechRate") == 0) {
			const flutter::EncodableValue arg = method_call.arguments()[0];
			if (std::holds_alternative<double>(arg)) {
				const double newRate = std::get<double>(arg);
				setRate(newRate);
				result->Success(1);
			}
			else result->Success(0);

		}
        else if (method_call.method_name().compare("setPitch") == 0) {
            const flutter::EncodableValue arg = method_call.arguments()[0];
            if (std::holds_alternative<double>(arg)) {
                const double newPitch = std::get<double>(arg);
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
