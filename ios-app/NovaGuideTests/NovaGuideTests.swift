import AVFoundation
import CoreGraphics
import simd
import SwiftUI
import XCTest
@testable import Kokobubu

final class CameraGeometryTests: XCTestCase {
    // fx = fy = 1000, principal point (960, 720): a 1920x1440 sensor image.
    let intrinsics = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))

    func testCenterPixelLiesStraightAhead() {
        let point = CameraGeometry.cameraPoint(pixel: CGPoint(x: 960, y: 720), depth: 0.5, intrinsics: intrinsics)
        XCTAssertEqual(point, SIMD3(0, 0, -0.5))
    }

    func testImageAxesMapToCameraAxes() {
        // Right of center in the image is +x; below center is -y (camera y points up).
        let point = CameraGeometry.cameraPoint(pixel: CGPoint(x: 1060, y: 820), depth: 2, intrinsics: intrinsics)
        XCTAssertEqual(point.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(point.y, -0.2, accuracy: 1e-6)
        XCTAssertEqual(point.z, -2, accuracy: 1e-6)
    }

    func testWorldPointUsesTheCaptureTimeCamera() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1, 2, 3, 1)  // camera moved, not rotated
        let world = CameraGeometry.worldPoint(pixel: CGPoint(x: 960, y: 720), depth: 1, intrinsics: intrinsics,
                                              cameraTransform: transform)
        XCTAssertEqual(world, SIMD3(1, 2, 2))
    }

    func testWorldRayIsUnitLengthFromTheCamera() {
        let ray = CameraGeometry.worldRay(pixel: CGPoint(x: 0, y: 0), intrinsics: intrinsics, cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(ray.origin, SIMD3(0, 0, 0))
        XCTAssertEqual(simd_length(ray.direction), 1, accuracy: 1e-5)
        XCTAssertLessThan(ray.direction.x, 0)
        XCTAssertGreaterThan(ray.direction.y, 0)
    }

    func testMetersFromPixels() {
        XCTAssertEqual(CameraGeometry.meters(pixels: 50, depth: 0.4, intrinsics: intrinsics), 0.02, accuracy: 1e-6)
    }
}

final class DepthSampleTests: XCTestCase {
    func testMedianIgnoresHolesAndOutliers() {
        var values = [Float](repeating: 1.0, count: 25)
        values[0] = 0  // hole
        values[1] = 9  // outlier
        let sample = DepthSample(width: 5, height: 5, values: values)
        XCTAssertEqual(sample.depth(atNormalized: CGPoint(x: 0.5, y: 0.5)), 1.0)
    }

    func testNoValidDepthGivesNil() {
        let sample = DepthSample(width: 2, height: 2, values: [0, 0, .nan, 0])
        XCTAssertNil(sample.depth(atNormalized: CGPoint(x: 0.5, y: 0.5)))
    }
}

final class GuidePlanTests: XCTestCase {
    func testDecodesTheServerAnswer() throws {
        let json = """
        {"device": {"type": "washing machine", "brand": "Maytag"}, "safe": true, "safetyNote": "", "uncertainty": "",
         "frame": {"width": 1600, "height": 1200}, "served": ["muse-spark-1.3", "sam-3.1"], "timings": {"plan": 4.1},
         "steps": [
          {"instruction": "Sıcaklığı sıcağa çevir.", "detail": "Soldaki düğme.", "target": "temperature knob", "success": "pointer at hot",
           "point": {"x": 0.21, "y": 0.41}, "box": {"x1": 0.18, "y1": 0.36, "x2": 0.24, "y2": 0.46, "confidence": 0.91},
           "boxMethod": "point", "setTo": {"label": "hot", "meaning": "sıcak", "point": {"x": 0.26, "y": 0.3}}},
          {"instruction": "Başlat.", "target": "start button", "success": "", "point": {"x": 0.8, "y": 0.4},
           "box": null, "boxMethod": "none", "setTo": null}
         ]}
        """
        let plan = try JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.deviceLabel, "Maytag · washing machine")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].markerPoint.x, 0.21, accuracy: 1e-9)  // the box center
        XCTAssertEqual(plan.steps[0].setTo?.meaning, "sıcak")
        XCTAssertEqual(plan.steps[0].detail, "Soldaki düğme.")
        XCTAssertNil(plan.steps[1].detail)  // an older server sends none
        XCTAssertEqual(plan.steps[1].markerPoint, NormalizedPoint(x: 0.8, y: 0.4))  // no box: Spark's point
        XCTAssertTrue(plan.isLocated)  // an older server sends one located plan
    }

    func testTheStepsPartIsNotLocated() throws {
        let json = """
        {"device": {"type": "oven", "brand": ""}, "safe": true, "safetyNote": "", "uncertainty": "", "located": false,
         "frame": {"width": 1600, "height": 1200}, "served": ["muse-spark-1.3"],
         "steps": [{"instruction": "Turn the knob.", "target": "knob", "success": "", "point": {"x": 0.5, "y": 0.5},
                    "box": null, "boxMethod": "pending", "setTo": null}]}
        """
        XCTAssertFalse(try JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8)).isLocated)
    }

    func testAQuestionComesWithItsOptions() throws {
        let json = """
        {"device": {"type": "washer", "brand": ""}, "safe": true, "safetyNote": "", "uncertainty": "", "located": true,
         "frame": {"width": 1600, "height": 1200}, "served": [], "steps": [],
         "question": {"kind": "choice", "text": "Hangi program?", "options": [
           {"label": "delicate", "meaning": "hassas"}, {"label": "", "meaning": "Evet"}]}}
        """
        let options = try XCTUnwrap(JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8)).question).options
        XCTAssertEqual(options[0].title, "delicate")
        XCTAssertEqual(options[0].subtitle, "hassas")
        XCTAssertEqual(options[0].answer, "delicate (hassas)")
        XCTAssertEqual(options[1].title, "Evet")
        XCTAssertNil(options[1].subtitle)
        XCTAssertEqual(options[1].answer, "Evet")
    }

    func testAPlanFromAnOlderServerHasNoQuestion() throws {
        let json = """
        {"device": {"type": "washer", "brand": ""}, "safe": true, "safetyNote": "", "uncertainty": "",
         "frame": {"width": 1, "height": 1}, "served": [], "steps": []}
        """
        XCTAssertNil(try JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8)).question)
    }

    func testAWeakFallbackBoxIsNotUsedForTheMarker() {
        let step = GuideStep(instruction: "", target: "", success: "", point: NormalizedPoint(x: 0.1, y: 0.1),
                             box: NormalizedBox(x1: 0.5, y1: 0.5, x2: 0.7, y2: 0.7), boxMethod: "fallback_weak", setTo: nil)
        XCTAssertEqual(step.markerPoint, NormalizedPoint(x: 0.1, y: 0.1))
    }
}

final class CropGeometryTests: XCTestCase {
    let image = CGSize(width: 1920, height: 1440)

    func testCropIsAboutThreeKnobDiametersAroundTheControl() {
        guard case .crop(let rect) = CropGeometry.crop(control: CGPoint(x: 960, y: 720), radius: 80, label: nil, imageSize: image) else {
            return XCTFail("expected a crop")
        }
        XCTAssertEqual(rect, CGRect(x: 704, y: 464, width: 512, height: 512))
    }

    func testCropReachesTheDialsTargetLabel() {
        guard case .crop(let rect) = CropGeometry.crop(control: CGPoint(x: 960, y: 720), radius: 80,
                                                       label: CGPoint(x: 960, y: 400), imageSize: image) else {
            return XCTFail("expected a crop")
        }
        XCTAssertTrue(rect.contains(CGPoint(x: 960, y: 400)))
    }

    func testCropIsClampedToTheImage() {
        guard case .crop(let rect) = CropGeometry.crop(control: CGPoint(x: 100, y: 100), radius: 80, label: nil, imageSize: image) else {
            return XCTFail("expected a crop")
        }
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 0)
    }

    func testAFarAwayControlIsTooSmallAndAnOffScreenOneIsReported() {
        XCTAssertEqual(CropGeometry.crop(control: CGPoint(x: 960, y: 720), radius: 20, label: nil, imageSize: image), .tooSmall)
        XCTAssertEqual(CropGeometry.crop(control: CGPoint(x: -5, y: 720), radius: 80, label: nil, imageSize: image), .offScreen)
    }
}

final class StepCheckTests: XCTestCase {
    func testDecodesAVerifyAnswer() throws {
        let json = #"{"status": "not_done", "observed": "warm", "correction": "Biraz sağa.", "seconds": 3.1, "served": ["muse-spark-1.3"]}"#
        let check = try JSONDecoder().decode(StepCheck.self, from: Data(json.utf8))
        XCTAssertEqual(check.status, .notDone)
        XCTAssertEqual(check.correction, "Biraz sağa.")
    }

    func testStepsAreVerifiableUnlessTheServerSaysNot() throws {
        let json = #"{"instruction": "", "target": "", "success": "", "point": {"x": 0, "y": 0}, "box": null, "boxMethod": "none", "setTo": null}"#
        XCTAssertTrue(try JSONDecoder().decode(GuideStep.self, from: Data(json.utf8)).isVerifiable)
        let pressOnly = json.replacingOccurrences(of: #""setTo": null"#, with: #""setTo": null, "verifiable": false"#)
        XCTAssertFalse(try JSONDecoder().decode(GuideStep.self, from: Data(pressOnly.utf8)).isVerifiable)
    }
}

final class VoiceCommandTests: XCTestCase {
    func testTurkishAndEnglishCommands() {
        XCTAssertEqual(VoiceCommand.match("Yaptım."), .done)
        XCTAssertEqual(VoiceCommand.match("tamam yaptım"), .done)
        XCTAssertEqual(VoiceCommand.match("Tekrarla"), .repeatStep)
        XCTAssertEqual(VoiceCommand.match("bir daha söyle"), .repeatStep)
        XCTAssertEqual(VoiceCommand.match("Geri dön"), .back)
        XCTAssertEqual(VoiceCommand.match("Geç"), .skip)
        XCTAssertEqual(VoiceCommand.match("Yeni soru"), .newQuestion)
        XCTAssertEqual(VoiceCommand.match("OK, done"), .done)
        XCTAssertEqual(VoiceCommand.match("Go back"), .back)
    }

    func testQuestionsAreNotCommands() {
        XCTAssertNil(VoiceCommand.match("Extra rinse ne demek?"))
        XCTAssertNil(VoiceCommand.match("tamam ama sıcaklık düğmesi hangisi"))  // long: a question
        XCTAssertNil(VoiceCommand.match("geçen sefer ne yaptım"))
        XCTAssertNil(VoiceCommand.match(""))
    }
}

final class WavTests: XCTestCase {
    func testHeaderAndPayload() {
        let wav = VoiceRecorder.wav(samples: [0, 1, -1], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 16_000)
        XCTAssertEqual(wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 6)
        XCTAssertEqual(Array(wav[46..<50]), [1, 0, 0xFF, 0xFF])
    }

    func testRmsOfSilenceAndFullScale() {
        XCTAssertEqual(VoiceRecorder.rms([0, 0, 0]), 0)
        XCTAssertEqual(VoiceRecorder.rms([Int16.max, Int16.max]), 1, accuracy: 1e-4)
    }
}

final class ServerRouterTests: XCTestCase {
    let internet = Route(kind: .internet, baseURL: URL(string: "https://guide.example.com")!, inviteCode: "AAAA-BBBB-CCCC")
    let tailscale = Route(kind: .tailscale, baseURL: URL(string: "http://mac.example.ts.net:9005")!)

    func testCandidatesNeedAnInviteCodeForTheInternetRoute() {
        XCTAssertEqual(Route.candidates(publicURL: "https://guide.example.com", inviteCode: "AAAA-BBBB-CCCC",
                                        tailscaleURL: "http://mac.example.ts.net:9005"), [internet, tailscale])
        XCTAssertEqual(Route.candidates(publicURL: "https://guide.example.com", inviteCode: " ",
                                        tailscaleURL: "http://mac.example.ts.net:9005"), [tailscale])
        XCTAssertEqual(Route.candidates(publicURL: "", inviteCode: "x", tailscaleURL: ""), [])
        XCTAssertNil(tailscale.client.inviteCode)  // the code never goes to the Mac over Tailscale
        XCTAssertEqual(internet.client.inviteCode, "AAAA-BBBB-CCCC")
    }

    func testTheInternetRouteIsTriedFirstAndTailscaleIsTheFallback() async {
        let router = ServerRouter { $0.kind == .internet ? .ok(keyLoaded: true) : .unreachable }
        await router.update([internet, tailscale])
        let first = await router.resolve()
        XCTAssertEqual(first, .connected(.internet, keyLoaded: true))

        let fallback = ServerRouter { $0.kind == .internet ? .unreachable : .ok(keyLoaded: true) }
        await fallback.update([internet, tailscale])
        let second = await fallback.resolve()
        XCTAssertEqual(second, .connected(.tailscale, keyLoaded: true))
    }

    func testARejectedCodeFallsBackButIsReportedWhenNothingElseAnswers() async {
        let router = ServerRouter { $0.kind == .internet ? .rejected("bad code") : .unreachable }
        await router.update([internet, tailscale])
        let state = await router.resolve()
        XCTAssertEqual(state, .rejected("bad code"))
    }

    func testAConnectionFailureMovesToTheNextRouteAndTriesOnce() async throws {
        let router = ServerRouter { _ in .ok(keyLoaded: true) }
        await router.update([internet, tailscale])
        var used: [URL?] = []
        let result: String = try await router.perform { client in
            used.append(client.baseURL)
            if client.baseURL == self.internet.baseURL { throw URLError(.cannotConnectToHost) }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(used, [internet.baseURL, tailscale.baseURL])
    }

    func testAServerErrorIsNotRetried() async {
        let router = ServerRouter { _ in .ok(keyLoaded: true) }
        await router.update([internet, tailscale])
        var calls = 0
        do {
            let _: String = try await router.perform { _ in
                calls += 1
                throw GuideClient.Failure.server(status: 502, message: "upstream")
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(calls, 1)
        }
    }
}

final class FrameOrientationTests: XCTestCase {
    func testLandscapeRightIsTheSensorImage() {
        XCTAssertEqual(FrameOrientation.landscapeRight.sensorPoint(CGPoint(x: 0.2, y: 0.7)), CGPoint(x: 0.2, y: 0.7))
        XCTAssertEqual(FrameOrientation.landscapeRight.imageOrientation, .up)
    }

    func testPortraitTurnsTheSensorImageClockwise() {
        // The upright frame's top-left corner is the sensor image's bottom-left; its top-right is the sensor's top-left.
        XCTAssertEqual(FrameOrientation.portrait.sensorPoint(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 1))
        XCTAssertEqual(FrameOrientation.portrait.sensorPoint(CGPoint(x: 1, y: 0)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(FrameOrientation.portrait.sensorPoint(CGPoint(x: 0.25, y: 0.6)), CGPoint(x: 0.6, y: 0.75))
        XCTAssertEqual(FrameOrientation.portrait.uprightSize(CGSize(width: 1920, height: 1440)), CGSize(width: 1440, height: 1920))
        XCTAssertEqual(FrameOrientation.portrait.imageOrientation, .right)
    }

    func testLandscapeLeftIsUpsideDown() {
        XCTAssertEqual(FrameOrientation.landscapeLeft.sensorPoint(CGPoint(x: 0.2, y: 0.3)), CGPoint(x: 0.8, y: 0.7))
        XCTAssertEqual(FrameOrientation.landscapeLeft.uprightSize(CGSize(width: 1920, height: 1440)), CGSize(width: 1920, height: 1440))
    }
}

final class GuideSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "NovaGuideTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testTheSpokenLanguageFollowsTheIPhoneByDefault() {
        XCTAssertEqual(GuideSettings(defaults: freshDefaults(), preferredLanguages: ["tr-TR"]).language.serverName, "Turkish")
        XCTAssertEqual(GuideSettings(defaults: freshDefaults(), preferredLanguages: ["en-US", "tr-TR"]).language.serverName, "English")
        XCTAssertEqual(GuideSettings(defaults: freshDefaults(), preferredLanguages: ["de-DE"]).language.serverName, "English")
    }

    func testGuidanceTogglesStartOn() {
        let settings = GuideSettings(defaults: freshDefaults())
        XCTAssertTrue(settings.speakAloud)
        XCTAssertTrue(settings.verifyEach)
        XCTAssertTrue(settings.autoContinue)
        XCTAssertTrue(settings.haptics)
        XCTAssertFalse(settings.record)
        XCTAssertEqual(settings.orientation, .automatic)
        XCTAssertEqual(settings.lens, .widest)  // more of the panel in view
        XCTAssertFalse(settings.highDetail)
        XCTAssertEqual(settings.torch, .automatic)
        XCTAssertTrue(settings.isAutomaticLanguage)
        XCTAssertFalse(settings.screenRecording)
    }

    func testConsentIsAskedUntilTheCurrentTermsAreAccepted() {
        let defaults = freshDefaults()
        let settings = GuideSettings(defaults: defaults)
        XCTAssertTrue(settings.needsConsent)
        settings.acceptTerms(on: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(settings.needsConsent)
        XCTAssertFalse(GuideSettings(defaults: defaults).needsConsent)  // kept across launches
        defaults.set("2026-01-01 1970-01-01T00:00:00Z", forKey: "acceptedTerms")
        XCTAssertTrue(GuideSettings(defaults: defaults).needsConsent)  // an older version asks again
    }
}

final class GuideTextTests: XCTestCase {
    func testMarkedDeviceWordsAreSplitOut() {
        XCTAssertEqual(GuideText.segments("Sıcaklık düğmesini «warm» konumuna getirin."), [
            .init(text: "Sıcaklık düğmesini ", isLabel: false),
            .init(text: "warm", isLabel: true),
            .init(text: " konumuna getirin.", isLabel: false),
        ])
        XCTAssertEqual(GuideText.segments("«Start/Pause»"), [.init(text: "Start/Pause", isLabel: true)])
    }

    func testTheScreenShowsQuotesAndUnmarkedTextIsUntouched() {
        XCTAssertEqual(GuideText.display("«Clock» tuşuna basın."), "“Clock” tuşuna basın.")
        XCTAssertEqual(GuideText.display("No labels here."), "No labels here.")
        XCTAssertEqual(GuideText.display("Broken «label"), "Broken «label")  // unbalanced: left as it is
    }

    func testLabelVoices() {
        XCTAssertEqual(UserLanguage.voice(forLanguageNamed: "English"), "en-US")
        XCTAssertEqual(UserLanguage.voice(forLanguageNamed: "German"), "de-DE")
        XCTAssertEqual(UserLanguage.voice(forLanguageNamed: nil), "en-US")
        XCTAssertEqual(UserLanguage.voice(forLanguageNamed: "Klingon"), "en-US")
    }
}

final class AutoLanguageTests: XCTestCase {
    func testCommandsTellTheirLanguage() {
        XCTAssertEqual(VoiceCommand.matchWithLanguage("yaptım")?.language, "Turkish")
        XCTAssertEqual(VoiceCommand.matchWithLanguage("Done.")?.language, "English")
        XCTAssertEqual(VoiceCommand.matchWithLanguage("say again")?.command, .repeatStep)
        XCTAssertNil(VoiceCommand.matchWithLanguage("What does extra rinse mean?"))
        XCTAssertEqual(VoiceCommand.match("Bu yanlış"), .wrong)
        XCTAssertEqual(VoiceCommand.match("That's wrong."), .wrong)
    }

    func testAQuestionsLanguageIsGuessedForTheFirstReply() {
        XCTAssertEqual(UserLanguage.guess("Çamaşırları nasıl yıkarım?")?.serverName, "Turkish")
        XCTAssertEqual(UserLanguage.guess("bu makineyi ac")?.serverName, "Turkish")
        XCTAssertEqual(UserLanguage.guess("How do I set the clock?")?.serverName, "English")
        XCTAssertNil(UserLanguage.guess("Bosch"))
    }

    func testExperimentalLanguagesAreGuessedFromTheirWriting() {
        XCTAssertEqual(UserLanguage.guess("¿Cómo enciendo esto?")?.serverName, "Spanish")
        XCTAssertEqual(UserLanguage.guess("Quero começar a lavar")?.serverName, "Portuguese")
        XCTAssertEqual(UserLanguage.guess("यह कैसे चालू करें")?.serverName, "Hindi")
        XCTAssertEqual(UserLanguage.guess("كيف أشغل هذا")?.serverName, "Arabic")
        XCTAssertEqual(UserLanguage.guess("怎么打开这个")?.serverName, "Mandarin Chinese")
    }

    func testExperimentalCommandsAndAnswers() {
        XCTAssertEqual(VoiceCommand.matchWithLanguage("Listo.")?.language, "Spanish")
        XCTAssertEqual(VoiceCommand.match("Incorrecto"), .wrong)
        XCTAssertEqual(VoiceCommand.match("Isso não"), .wrong)
        XCTAssertEqual(VoiceCommand.matchWithLanguage("हो गया")?.command, .done)
        XCTAssertEqual(VoiceCommand.matchWithLanguage("फिर से शुरू")?.command, .newQuestion)
        XCTAssertEqual(VoiceCommand.matchWithLanguage("تم")?.language, "Arabic")
        XCTAssertEqual(VoiceCommand.matchWithLanguage("下一步。")?.command, .skip)
        XCTAssertNil(VoiceCommand.match("¿Qué hago?"))
        XCTAssertEqual(VoiceCommand.confirmation("Sí"), true)
        XCTAssertEqual(VoiceCommand.confirmation("Não"), false)
        XCTAssertEqual(VoiceCommand.confirmation("नहीं"), false)
        XCTAssertEqual(VoiceCommand.confirmation("نعم"), true)
        XCTAssertEqual(VoiceCommand.confirmation("没解决"), false)
    }

    func testTheLanguageSpokenNowWinsASharedWord() {
        XCTAssertEqual(VoiceCommand.matchWithLanguage("anterior", preferring: "Portuguese")?.language, "Portuguese")
        XCTAssertEqual(VoiceCommand.matchWithLanguage("anterior", preferring: "Spanish")?.language, "Spanish")
        XCTAssertEqual(VoiceCommand.matchWithLanguage("ok", preferring: "Hindi")?.language, "Hindi")
        XCTAssertEqual(VoiceCommand.matchWithLanguage("ok", preferring: "Turkish")?.language, "English")
    }

    func testAnIPhoneInAnExperimentalLanguageStartsInIt() {
        XCTAssertEqual(UserLanguage.matching(preferred: ["es-US"]).serverName, "Spanish")
        XCTAssertEqual(UserLanguage.matching(preferred: ["zh-Hans-US"]).serverName, "Mandarin Chinese")
        XCTAssertEqual(UserLanguage.matching(preferred: ["fr-FR"]).serverName, "English")
    }

    func testEveryExperimentalLanguageSpeaksEveryFixedLine() {
        let lines = GuideModel.lookingPhrases + [
            "Kokobubu is ready to help.", "How can I help you?", "Done. It should be working now.",
            "Tap the right control on the screen.", "Okay, next step.", "No problem, let's try again.",
            "We seem stuck. Shall I look at this again?", "Okay.", "Did this solve it?",
            "It's still working. When it finishes, point the camera here and check again.",
            "I can't confirm the result from here.",
            "I couldn't solve this. Check the device's manual or contact service.",
            "Point the camera at the control, then check again.",
            "Move the phone closer to the control, then check again.", "Hold the phone steady, then check again.",
        ]
        for language in UserLanguage.all where language.experimental {
            for line in lines {
                XCTAssertNotEqual(language.phrase(line), line, "\(language.serverName): \(line)")
            }
            XCTAssertNotNil(Speaker.bestVoice(for: language.voice), language.serverName)
        }
    }
}

final class SpeedTestTests: XCTestCase {
    func testTheDefaultSendsNoSparkSetting() throws {
        let suite = "speed-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GuideSettings(defaults: defaults)
        XCTAssertNil(settings.sparkChoice)
        settings.sparkEffort = .low
        XCTAssertEqual(settings.sparkChoice, GuideClient.SparkChoice(provider: "meta", effort: "low"))
        settings.sparkProvider = .baseten
        XCTAssertEqual(GuideSettings(defaults: defaults).sparkChoice, GuideClient.SparkChoice(provider: "baseten", effort: "low"))
    }

    func testTheSummaryListsOnlyWhatWasMeasured() {
        XCTAssertTrue(TaskTimings().isEmpty)
        let timings = TaskTimings(steps: 3.44, markers: 7.1, setting: "Meta Minimal")
        let number = { (value: Double) in value.formatted(.number.precision(.fractionLength(1))) }
        XCTAssertFalse(timings.isEmpty)
        XCTAssertEqual(timings.summary, "\(String(localized: "Steps", bundle: .ui)) \(String(localized: "\(number(3.44)) s", bundle: .ui)) · "
            + "\(String(localized: "Markers", bundle: .ui)) \(String(localized: "\(number(7.1)) s", bundle: .ui)) · Meta Minimal")
    }
}

final class AutoTorchTests: XCTestCase {
    func testTheTorchComesOnAfterTwoSecondsOfDark() {
        var torch = AutoTorch()
        XCTAssertFalse(torch.update(lumens: 60, at: 0))
        XCTAssertFalse(torch.update(lumens: 60, at: 1.5))
        XCTAssertTrue(torch.update(lumens: 60, at: 2.1))
    }

    func testAShortShadowDoesNotLightIt() {
        var torch = AutoTorch()
        _ = torch.update(lumens: 60, at: 0)
        _ = torch.update(lumens: 900, at: 1)  // light again: the wait starts over
        XCTAssertFalse(torch.update(lumens: 60, at: 2.5))
    }

    private func litTorch() -> AutoTorch {
        var torch = AutoTorch()
        torch.update(lumens: 60, at: 0)
        torch.update(lumens: 60, at: 2.5)  // on at 2.5, first look at the room at 10.5
        return torch
    }

    func testItGoesOffForAMomentAndStaysOffInALitRoom() {
        var torch = litTorch()
        XCTAssertTrue(torch.isLit)
        XCTAssertTrue(torch.update(lumens: 300, at: 10))
        XCTAssertFalse(torch.update(lumens: 300, at: 10.6))  // measuring
        XCTAssertTrue(torch.isProbing)
        XCTAssertFalse(torch.update(lumens: 900, at: 11.3))  // bright enough
        XCTAssertFalse(torch.isOn)
        XCTAssertFalse(torch.update(lumens: 900, at: 40))
    }

    func testInTheDarkItComesBackAndLooksLessOften() {
        var torch = litTorch()
        torch.update(lumens: 300, at: 10.6)
        XCTAssertTrue(torch.update(lumens: 60, at: 11.3))  // still dark: on again, next look 16 s later
        XCTAssertTrue(torch.update(lumens: 300, at: 20))
        XCTAssertFalse(torch.update(lumens: 300, at: 27.4))
        XCTAssertTrue(torch.update(lumens: 60, at: 28.1))
    }

    func testMovingIntoALitRoomTurnsItOffWithoutWaiting() {
        var torch = litTorch()
        torch.update(lumens: 300, at: 4.1)  // what the torch itself gives
        XCTAssertTrue(torch.update(lumens: 800, at: 5))
        XCTAssertFalse(torch.update(lumens: 800, at: 6.1))
        XCTAssertFalse(torch.isOn)
    }

    func testItDoesNotBlinkWhileNovaIsBusy() {
        var torch = litTorch()
        XCTAssertTrue(torch.update(lumens: 300, at: 11, hold: true))
        XCTAssertTrue(torch.update(lumens: 300, at: 30, hold: true))
        XCTAssertFalse(torch.update(lumens: 300, at: 30.1))  // free again: it looks
    }

    func testAResetTurnsItOff() {
        var torch = litTorch()
        torch.reset()
        XCTAssertFalse(torch.isLit)
    }
}

final class LiveTranscriberTests: XCTestCase {
    func testServerMessages() {
        XCTAssertEqual(LiveTranscriber.event(from: #"{"type":"transcript","transcript":"nasıl","final":false}"#), .partial("nasıl"))
        XCTAssertEqual(LiveTranscriber.event(from: #"{"type":"speechEnd","turnId":1}"#), .speechEnded)
        XCTAssertEqual(LiveTranscriber.event(from: #"{"type":"speechComplete","turnId":1,"transcript":"Nasıl?"}"#), .final("Nasıl?"))
        XCTAssertEqual(LiveTranscriber.event(from: #"{"type":"error","message":"x"}"#), .failed)
        XCTAssertNil(LiveTranscriber.event(from: #"{"type":"ready"}"#))
        XCTAssertNil(LiveTranscriber.event(from: "not json"))
    }

    func testTheTimingsSayWhichRouteWasUsed() {
        XCTAssertTrue(TaskTimings(transcript: 0.4, liveVoice: true).summary.hasPrefix(String(localized: "Live voice", bundle: .ui)))
        XCTAssertTrue(TaskTimings(transcript: 1.9).summary.hasPrefix(String(localized: "Voice", bundle: .ui)))
    }
}

final class ReviewTests: XCTestCase {
    func testAReviewDecodes() throws {
        let json = """
        {"verdict": "step_ok", "explanation": "«warm» görünüyor.", "point": {"x": 0.2, "y": 0.4}, "box": null,
         "boxMethod": "point", "seconds": 3.1, "served": ["muse-spark-1.3"]}
        """
        let review = try JSONDecoder().decode(GuideClient.Review.self, from: Data(json.utf8))
        XCTAssertEqual(review.verdict, .stepOK)
        XCTAssertEqual(review.point, NormalizedPoint(x: 0.2, y: 0.4))
        let wrong = #"{"verdict": "wrong_step", "explanation": "Yok.", "point": null, "box": null, "boxMethod": "none"}"#
        XCTAssertEqual(try JSONDecoder().decode(GuideClient.Review.self, from: Data(wrong.utf8)).verdict, .wrongStep)
    }
}

final class InterfaceLanguageTests: XCTestCase {
    func testTheChoiceIsKeptAndTheIPhoneLanguageClearsIt() throws {
        let suite = "interface-\(UUID().uuidString)"
        addTeardownBlock { Bundle.ui = .main }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GuideSettings(defaults: defaults)
        XCTAssertEqual(settings.interfaceLanguage, .iPhone)
        settings.interfaceLanguage = .turkish
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["tr"])
        XCTAssertEqual(GuideSettings(defaults: defaults).interfaceLanguage, .turkish)
        XCTAssertEqual(String(localized: "Did this solve it?", bundle: .ui), "Sorun çözüldü mü?")  // at once, without a new launch
        settings.interfaceLanguage = .english
        XCTAssertEqual(String(localized: "Did this solve it?", bundle: .ui), "Did this solve it?")
        settings.interfaceLanguage = .iPhone
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }
}

final class GreetingTests: XCTestCase {
    func testEyeLooksWhereThePhoneMoves() {
        // The picture slides left when the phone moves right, and down when it moves up.
        XCTAssertEqual(CameraGaze.look(forSlide: CGPoint(x: -40, y: 0), screenWidth: 400).x, 1)
        XCTAssertEqual(CameraGaze.look(forSlide: CGPoint(x: 40, y: 0), screenWidth: 400).x, -1)
        XCTAssertEqual(CameraGaze.look(forSlide: CGPoint(x: 0, y: 40), screenWidth: 400).y, -1)
        XCTAssertEqual(CameraGaze.look(forSlide: CGPoint(x: 2, y: -2), screenWidth: 400), .zero)
    }

    func testInviteLinkGivesTheCode() throws {
        XCTAssertEqual(Route.inviteCode(from: try XCTUnwrap(URL(string: "kokobubu://invite/ABCD-1234"))), "ABCD-1234")
        XCTAssertEqual(Route.inviteCode(from: try XCTUnwrap(URL(string: "kokobubu-dev://invite/ABCD-1234"))), "ABCD-1234")
        XCTAssertNil(Route.inviteCode(from: try XCTUnwrap(URL(string: "https://invite/ABCD-1234"))))
        XCTAssertNil(Route.inviteCode(from: try XCTUnwrap(URL(string: "kokobubu://other/ABCD-1234"))))
        XCTAssertNil(Route.inviteCode(from: try XCTUnwrap(URL(string: "kokobubu://invite/ab"))))
        XCTAssertNil(Route.inviteCode(from: try XCTUnwrap(URL(string: "kokobubu://invite/AB%20CD"))))
    }

    func testPlanCanAskToSeeSomethingElse() throws {
        let json = """
        {"device": {"type": "monitor", "brand": ""}, "safe": true, "safetyNote": "", "uncertainty": "",
         "frame": {"width": 1600, "height": 900}, "served": [], "steps": [], "finding": "no mouse in view",
         "showRequest": {"what": "Show me the mouse.", "why": "I'll check its light."}}
        """
        let plan = try JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.showRequest?.what, "Show me the mouse.")
        XCTAssertEqual(plan.finding, "no mouse in view")
    }

    @MainActor func testDoneLineSaysWhatChangedAndHowFarToGo() {
        let phrase: (String) -> String = { $0 }
        XCTAssertEqual(GuideModel.doneLine(confirmation: "Orange is set.", ready: "Okay.", stepsLeft: 1, goesOn: false, phrase: phrase),
                       "Orange is set. Last step.")
        XCTAssertEqual(GuideModel.doneLine(confirmation: " ", ready: "Okay.", stepsLeft: 2, goesOn: false, phrase: phrase),
                       "Okay. Two steps left.")
        XCTAssertEqual(GuideModel.doneLine(confirmation: nil, ready: "Good.", stepsLeft: 0, goesOn: false, phrase: phrase), "Good.")
        XCTAssertEqual(GuideModel.doneLine(confirmation: nil, ready: "Good.", stepsLeft: 1, goesOn: true, phrase: phrase), "Good.")
    }

    @MainActor func testLookingPhraseNeverRepeatsAndIsTranslated() {
        var last: String?
        for _ in 0..<50 {
            let phrase = GuideModel.lookingPhrase(after: last)
            XCTAssertNotEqual(phrase, last)
            last = phrase
        }
        let turkish = UserLanguage.all[0]
        for phrase in GuideModel.lookingPhrases {
            XCTAssertNotEqual(turkish.phrase(phrase), phrase)
        }
    }

    func testBothSpokenLinesExistInTurkish() {
        let turkish = UserLanguage.named("Turkish")
        XCTAssertEqual(turkish.phrase("Kokobubu is ready to help."), "Kokobubu yardıma hazır.")
        XCTAssertEqual(turkish.phrase("How can I help you?"), "Sana nasıl yardımcı olabilirim?")
    }
}

final class OutcomeTests: XCTestCase {
    func testSpokenAnswersToDidThisSolveIt() {
        XCTAssertEqual(VoiceCommand.confirmation("Evet çözüldü"), true)
        XCTAssertEqual(VoiceCommand.confirmation("Yes it worked"), true)
        XCTAssertEqual(VoiceCommand.confirmation("Hayır"), false)
        XCTAssertEqual(VoiceCommand.confirmation("Hayır olmadı"), false)
        XCTAssertEqual(VoiceCommand.confirmation("No, not yet"), false)
        XCTAssertNil(VoiceCommand.confirmation("Ekran hâlâ siyah kalıyor ve hiçbir şey olmuyor"))
    }

    func testMotionFromTheServer() {
        var step = GuideStep(instruction: "", target: "", success: "", point: NormalizedPoint(x: 0, y: 0), box: nil,
                             boxMethod: "point", setTo: nil)
        XCTAssertNil(step.motionKind)
        step.motion = "turn_counterclockwise"
        XCTAssertEqual(step.motionKind, .turnCounterclockwise)
        step.motion = "unknown"
        XCTAssertNil(step.motionKind)
    }
}

final class ContinuingPlanTests: XCTestCase {
    func testAPlanSaysWhenTheTaskGoesOn() throws {
        let json = """
        {"device": {"type": "iPhone", "brand": ""}, "safe": true, "safetyNote": "", "uncertainty": "", "continues": true,
         "remaining": "«General»", "frame": {"width": 1, "height": 1}, "served": [], "steps": []}
        """
        let plan = try JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.goesOn)
        XCTAssertEqual(plan.remaining, "«General»")
        let older = #"{"device": {"type": "x", "brand": ""}, "safe": true, "safetyNote": "", "uncertainty": "", "frame": {"width": 1, "height": 1}, "served": [], "steps": []}"#
        XCTAssertFalse(try JSONDecoder().decode(GuidePlan.self, from: Data(older.utf8)).goesOn)
    }
}

final class VoiceChoiceTests: XCTestCase {
    func testAVoiceIsFoundInTheLanguageAndNeverANoveltyOne() throws {
        let voice = try XCTUnwrap(Speaker.bestVoice(for: "en-US"))
        XCTAssertTrue(voice.language.hasPrefix("en"))
        XCTAssertFalse(voice.voiceTraits.contains(.isNoveltyVoice))
        XCTAssertFalse(Speaker.voiceDescription(for: "en-US").isEmpty)
    }
}

final class SoundEffectsTests: XCTestCase {
    func testEveryEffectIsAPlayableSound() throws {
        for effect in SoundEffects.Effect.allCases {
            let player = try AVAudioPlayer(data: SoundEffects.wav(effect))
            XCTAssertGreaterThan(player.duration, 0.03)
            XCTAssertLessThan(player.duration, 0.7)
        }
    }

    func testAColorFromTheServerIsReadOnlyWhenItIsAHexCode() {
        XCTAssertNotNil(Color(hex: "#F28C28"))
        XCTAssertNil(Color(hex: "orange"))
        XCTAssertNil(Color(hex: nil))
    }
}

final class FocusGeometryTests: XCTestCase {
    func testATapBecomesAPointInTheCameraImage() {
        let point = FocusGeometry.point(tap: CGPoint(x: 100, y: 200), viewSize: CGSize(width: 400, height: 800),
                                        displayTransform: .identity)
        XCTAssertEqual(point, CGPoint(x: 0.25, y: 0.25))
    }

    func testAPortraitScreenTurnsThePoint() {
        // Portrait: the image's x runs down the screen, and its y runs from right to left.
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let point = FocusGeometry.point(tap: CGPoint(x: 300, y: 200), viewSize: CGSize(width: 400, height: 800),
                                        displayTransform: portrait)
        XCTAssertEqual(point?.x ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? -1, 0.25, accuracy: 0.001)
    }

    func testAPointStaysInsideTheImage() {
        let point = FocusGeometry.point(tap: CGPoint(x: 900, y: -50), viewSize: CGSize(width: 400, height: 800),
                                        displayTransform: .identity)
        XCTAssertEqual(point, CGPoint(x: 1, y: 0))
        XCTAssertNil(FocusGeometry.point(tap: .zero, viewSize: .zero, displayTransform: .identity))
    }
}

final class BuildStampTests: XCTestCase {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    func testTheCommitAndTheTimeAreShown() {
        let text = BuildStamp.text(commit: "2ab53c1+", built: "2026-10-31T03:14:00Z", timeZone: pacific, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.hasPrefix("2ab53c1+ · Oct 30"), text)
        XCTAssertTrue(text.contains("8:14"), text)
    }

    func testAMissingStampStillSaysSomething() {
        XCTAssertEqual(BuildStamp.text(commit: "2ab53c1", built: nil), "2ab53c1")
        XCTAssertFalse(BuildStamp.text(commit: nil, built: nil).isEmpty)
    }
}

final class GoalCheckTests: XCTestCase {
    func testADeviceStillWorkingIsReadFromTheServer() throws {
        let data = Data(#"{"status":"in_progress","observed":"Setting Language...","correction":""}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StepCheck.self, from: data).status, .inProgress)
    }
}

final class StepCheckViewTests: XCTestCase {
    private func step(check: String?, verifiable: Bool?) -> GuideStep {
        GuideStep(instruction: "", target: "", success: "", point: NormalizedPoint(x: 0, y: 0), box: nil, boxMethod: "none",
                  setTo: nil, check: check, verifiable: verifiable)
    }

    func testAWholeViewStepIsCheckedThoughAnOlderFieldSaysNo() {
        let whole = step(check: "whole_view", verifiable: false)
        XCTAssertTrue(whole.isVerifiable)
        XCTAssertTrue(whole.checksWholeView)
    }

    func testAStepWithNoVisibleResultIsNotChecked() {
        XCTAssertFalse(step(check: "none", verifiable: false).isVerifiable)
    }

    func testAnOlderServerStillDecides() {
        XCTAssertFalse(step(check: nil, verifiable: false).isVerifiable)
        XCTAssertTrue(step(check: nil, verifiable: nil).isVerifiable)
        XCTAssertFalse(step(check: "close_up", verifiable: true).checksWholeView)
    }
}

final class CardPlaceTests: XCTestCase {
    private let bottomRight = CardPlace(top: false, left: false)

    func testADragAwayFromTheEdgeMovesTheCard() {
        XCTAssertEqual(bottomRight.afterDrag(CGSize(width: 0, height: -200), land: false),
                       .move(CardPlace(top: true, left: false)))
        XCTAssertEqual(CardPlace(top: true, left: false).afterDrag(CGSize(width: 0, height: 200), land: false),
                       .move(bottomRight))
    }

    func testLandscapeReachesEveryCorner() {
        XCTAssertEqual(bottomRight.afterDrag(CGSize(width: -200, height: 0), land: true),
                       .move(CardPlace(top: false, left: true)))
        XCTAssertEqual(bottomRight.afterDrag(CGSize(width: -200, height: -200), land: true),
                       .move(CardPlace(top: true, left: true)))
    }

    func testPortraitIgnoresASidewaysDrag() {
        XCTAssertEqual(bottomRight.afterDrag(CGSize(width: -200, height: 0), land: false), .stay)
    }

    func testADragTowardTheEdgeFoldsTheCardAndASmallOneDoesNothing() {
        XCTAssertEqual(bottomRight.afterDrag(CGSize(width: 0, height: 40), land: false), .fold)
        XCTAssertEqual(CardPlace(top: true, left: false).afterDrag(CGSize(width: 0, height: -40), land: false), .fold)
        XCTAssertEqual(bottomRight.afterDrag(CGSize(width: 0, height: -20), land: false), .stay)
    }

    func testVoiceOverVisitsEveryCornerInTurn() {
        var place = bottomRight
        var seen: [String] = []
        for _ in 0..<4 {
            place = place.next(land: true)
            seen.append(place.rawValue)
        }
        XCTAssertEqual(Set(seen).count, 4)
        XCTAssertEqual(place, bottomRight)
    }

    func testThePlaceSurvivesARestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CardPlaceTests"))
        defaults.removePersistentDomain(forName: "CardPlaceTests")
        GuideSettings(defaults: defaults).cardLandscape = CardPlace(top: true, left: true)
        let reopened = GuideSettings(defaults: defaults)
        XCTAssertEqual(reopened.cardLandscape, CardPlace(top: true, left: true))
        XCTAssertEqual(reopened.cardPortrait, .portraitDefault)
        XCTAssertFalse(reopened.cardDocked)
        reopened.cardDocked = true
        XCTAssertTrue(GuideSettings(defaults: defaults).cardDocked)
    }
}
