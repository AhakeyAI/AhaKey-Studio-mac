import Foundation
import XCTest
@testable import AhaKeyConfig

final class OLEDLocalizationTests: XCTestCase {
    func testSavedConfigurationOmitsDisplayStatusAndPreservesDeviceSettings() throws {
        var draft = AhaKeyModeDraft.default(for: .mode3)
        draft.oled.localAssetPath = "/Users/example/Pictures/自定义.gif"
        draft.oled.framesPerSecond = 24
        draft.oled.statusLine = "Uploaded 5 frames"
        draft.keys[0].description = "My voice key"

        let data = try JSONEncoder().encode(draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oled = try XCTUnwrap(object["oled"] as? [String: Any])
        XCTAssertNil(oled["statusLine"])

        let restored = try JSONDecoder().decode(AhaKeyModeDraft.self, from: data)
        XCTAssertEqual(restored.oled.localAssetPath, draft.oled.localAssetPath)
        XCTAssertEqual(restored.oled.framesPerSecond, 24)
        XCTAssertEqual(restored.keys, draft.keys)
        XCTAssertEqual(restored.lightBar, draft.lightBar)
        XCTAssertEqual(restored.oled.statusLine, AhaKeyOLEDDraft.default(for: .mode3).statusLine)
        XCTAssertTrue(restored.oled.hasSameDeviceConfiguration(as: draft.oled))
    }

    func testLegacyStatusInAnyLanguageIsRebuiltForEveryMode() throws {
        for mode in AhaKeyModeSlot.allCases {
            var original = AhaKeyModeDraft.default(for: mode)
            original.oled.localAssetPath = "/Users/example/Pictures/custom.gif"
            original.oled.framesPerSecond = 18
            original.keys[0].description = "ユーザー設定"
            let data = try JSONEncoder().encode(original)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            for legacyStatus in ["已上传 5 帧", "Uploaded 5 frames", "5 フレームを転送しました"] {
                var legacy = object
                var oled = try XCTUnwrap(legacy["oled"] as? [String: Any])
                oled["statusLine"] = legacyStatus
                legacy["oled"] = oled

                let restored = try JSONDecoder().decode(
                    AhaKeyModeDraft.self,
                    from: JSONSerialization.data(withJSONObject: legacy)
                )
                XCTAssertEqual(restored, original)
                XCTAssertEqual(restored.keys[0].description, "ユーザー設定")
                XCTAssertEqual(restored.oled.statusLine, AhaKeyOLEDDraft.default(for: mode).statusLine)
                XCTAssertNotEqual(restored.oled.statusLine, legacyStatus)
            }
        }
    }

    func testDisplayStatusDoesNotMarkHardwareConfigurationAsChanged() {
        let original = AhaKeyModeDraft.default(for: .mode0)
        var changed = original
        changed.oled.statusLine = "Uploading…"
        XCTAssertNotEqual(changed, original, "SwiftUI must observe status-only changes")
        XCTAssertTrue(changed.oled.hasSameDeviceConfiguration(as: original.oled))

        changed.oled.framesPerSecond = 24
        XCTAssertFalse(changed.oled.hasSameDeviceConfiguration(as: original.oled))
        changed = original
        changed.oled.localAssetPath = "/Users/example/Pictures/other.gif"
        XCTAssertFalse(changed.oled.hasSameDeviceConfiguration(as: original.oled))
    }

    func testLegacyOLEDWithoutFrameRateKeepsDefaultAndIgnoresStatus() throws {
        let legacy = Data(#"{"localAssetPath":"/tmp/legacy.gif","statusLine":"旧状态"}"#.utf8)
        let restored = try JSONDecoder().decode(AhaKeyOLEDDraft.self, from: legacy)
        XCTAssertEqual(restored.localAssetPath, "/tmp/legacy.gif")
        XCTAssertEqual(restored.framesPerSecond, 12)
        XCTAssertTrue(restored.statusLine.isEmpty)
    }
}
