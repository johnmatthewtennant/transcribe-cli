import Testing
@testable import transcribe

@Suite("AudioDeviceUtils")
struct AudioDeviceUtilsTests {
    let devices: [AudioInputDevice] = [
        AudioInputDevice(id: 42, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice"),
        AudioInputDevice(id: 77, name: "AirPods Pro", uid: "28-AB-EB-12-34-56:input"),
        AudioInputDevice(id: 99, name: "Blue Yeti", uid: "USB-BlueYeti-001"),
    ]

    @Test func exactNameMatch() {
        let result = findMatchingDevice(query: "AirPods Pro", in: devices)
        #expect(result?.id == 77)
    }

    @Test func exactUIDMatch() {
        let result = findMatchingDevice(query: "USB-BlueYeti-001", in: devices)
        #expect(result?.id == 99)
    }

    @Test func partialCaseInsensitiveMatch() {
        let result = findMatchingDevice(query: "airpods", in: devices)
        #expect(result?.id == 77)
    }

    @Test func partialNameMatch() {
        let result = findMatchingDevice(query: "Yeti", in: devices)
        #expect(result?.id == 99)
    }

    @Test func noMatch() {
        let result = findMatchingDevice(query: "Nonexistent Device", in: devices)
        #expect(result == nil)
    }

    @Test func emptyDeviceList() {
        let result = findMatchingDevice(query: "anything", in: [])
        #expect(result == nil)
    }

    @Test func exactNamePrioritizedOverPartial() {
        // "AirPods Pro" exact match should win over partial match on "AirPods Pro Max"
        let devicesWithSimilar = devices + [
            AudioInputDevice(id: 88, name: "AirPods Pro Max", uid: "AirPodsProMax-UID")
        ]
        let result = findMatchingDevice(query: "AirPods Pro", in: devicesWithSimilar)
        #expect(result?.id == 77)
    }

    @Test func uidMatchPrioritizedOverPartialName() {
        // If query matches a UID exactly, that should win over partial name match
        let result = findMatchingDevice(query: "BuiltInMicrophoneDevice", in: devices)
        #expect(result?.id == 42)
    }
}
