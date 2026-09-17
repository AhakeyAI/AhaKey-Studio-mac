import Foundation
import XCTest
@testable import AhaKeyConfig

final class LocalizationTests: XCTestCase {
    private var languages: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted()
    }

    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func resource(_ language: String, table: String = "Localizable", extension ext: String) throws -> [String: Any] {
        guard let url = try bundle(language).url(forResource: table, withExtension: ext) else { return [:] }
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private func keys(_ language: String) throws -> Set<String> {
        Set(try resource(language, extension: "strings").keys)
            .union(try resource(language, extension: "stringsdict").keys)
    }

    func testEveryShippedLanguageContainsAllAppAndVibeBarTranslations() throws {
        let source = try XCTUnwrap(Bundle.main.developmentLocalization)
        let expected = try keys(source)
        XCTAssertGreaterThan(expected.count, 950)
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("zh-Hans"))
        for language in languages {
            XCTAssertEqual(try keys(language), expected, language)
            for (key, value) in try resource(language, extension: "strings") {
                XCTAssertFalse(try XCTUnwrap(value as? String).isEmpty, "\(language): \(key)")
            }
        }
        XCTAssertEqual(try bundle("en").localizedString(forKey: "vibebar.approval.manual", value: nil, table: nil), "Manual")
        XCTAssertEqual(try bundle("en").localizedString(forKey: "device.lighting.off", value: nil, table: nil), "Off")
        XCTAssertEqual(try bundle("en").localizedString(forKey: "text.3fd47edce45b", value: nil, table: nil), "Close")
    }

    func testLocalizedInterpolationPreservesErrorDetails() throws {
        let expected = ["en": "Intel HEX line 12 uses unsupported record type 0x0A.",
                        "zh-Hans": "Intel HEX 第 12 行使用了不支持的记录类型 0x0A。"]
        for (language, text) in expected {
            let actual = String(
                localized: "text.77e783bc51f4",
                defaultValue: "Intel HEX 第 \(String(12)) 行使用了不支持的记录类型 0x\(String(format: "%02X", 10))。",
                bundle: try bundle(language)
            )
            XCTAssertEqual(actual, text)
        }
    }

    func testNativePluralsHandleZeroOneAndManyFrames() throws {
        for count in [0, 1, 2, 70] {
            let english = String(localized: "text.debf58659f92", defaultValue: "已自动同步默认动图（\(count) 帧）。",
                                 bundle: try bundle("en"), locale: Locale(identifier: "en"))
            XCTAssertEqual(english, "Default animation synced automatically (\(count) \(count == 1 ? "frame" : "frames")).")
            let chinese = String(localized: "text.debf58659f92", defaultValue: "已自动同步默认动图（\(count) 帧）。",
                                 bundle: try bundle("zh-Hans"), locale: Locale(identifier: "zh-Hans"))
            XCTAssertEqual(chinese, "已自动同步默认动图（\(count) 帧）。")
            let uploaded = String(localized: "text.344fda8b5178",
                                  defaultValue: "已上传 \(count) 帧到设备，槽位起点 \(12)；切换模式时会先显示描述，再回到当前模式动图。",
                                  bundle: try bundle("en"), locale: Locale(identifier: "en"))
            XCTAssertEqual(uploaded, "Uploaded \(count) \(count == 1 ? "frame" : "frames") starting at slot 12. Mode switches show descriptions briefly before the animation.")
        }
    }

    func testEveryShippedPluralHasCompleteRules() throws {
        for language in languages {
            for (key, value) in try resource(language, extension: "stringsdict") {
                let entry = try XCTUnwrap(value as? [String: Any])
                XCTAssertNotNil(entry["NSStringLocalizedFormatKey"], "\(language): \(key)")
                for rule in entry.values.compactMap({ $0 as? [String: Any] }) {
                    guard rule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" else { continue }
                    XCTAssertNotNil(rule["NSStringFormatValueTypeKey"], "\(language): \(key)")
                    XCTAssertFalse(try XCTUnwrap(rule["other"] as? String).isEmpty, "\(language): \(key)")
                }
            }
        }
    }

    func testJapaneseFixtureSupportsArgumentReorderingAndOtherOnlyPlural() throws {
        // Test-only resources: Japanese is not advertised or shipped until its translation is complete.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ja.lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let dictionary: [String: Any] = ["fixture.frames": [
            "NSStringLocalizedFormatKey": "%1$#@count@",
            "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                      "other": "%2$@ に %1$lld フレームを転送しました。"]
        ]]
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Localizable.stringsdict"))
        let fixture = try XCTUnwrap(Bundle(url: directory))
        for count in [0, 1, 2] {
            let actual = String(localized: "fixture.frames", defaultValue: "Uploaded \(count) frames to \("LCD").",
                                bundle: fixture, locale: Locale(identifier: "ja"))
            XCTAssertEqual(actual, "LCD に \(count) フレームを転送しました。")
        }
    }

    func testLiteralPercentSurvivesLocalizedInterpolation() throws {
        let value = String(localized: "text.1bf4726f8484", defaultValue: "亮度 \(String(75))%", bundle: try bundle("en"))
        XCTAssertEqual(value, "Brightness 75%")
    }

    func testModelLocalizationDoesNotChangeStoredOrFirmwareValues() throws {
        XCTAssertEqual(LightEffectStyle.off.firmwareIndex, 0)
        XCTAssertEqual(String(data: try JSONEncoder().encode(LightEffectStyle.off), encoding: .utf8), "\"off\"")
        XCTAssertEqual(try JSONDecoder().decode(AhaKeyModeSlot.self, from: Data("2".utf8)), .mode2)
        XCTAssertEqual(AhaKeyModeSlot.mode2.title, String(localized: "studio.mode.title", defaultValue: "模式 \(3)"))
        XCTAssertEqual(AhaKeyModeSlot.mode2.defaultName, "Codex")
        XCTAssertFalse(LightEffectStyle.off.title.isEmpty)
        XCTAssertTrue(try XCTUnwrap(FirmwareImageValidationError.invalidChecksum(line: 12).errorDescription).contains("12"))
    }

    func testSystemPermissionPromptsAreLocalizedInEveryShippedLanguage() throws {
        for language in languages {
            let info = try resource(language, table: "InfoPlist", extension: "strings")
            for key in ["NSBluetoothAlwaysUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
                XCTAssertFalse(try XCTUnwrap(info[key] as? String).isEmpty, "\(language): \(key)")
            }
        }
    }
}
