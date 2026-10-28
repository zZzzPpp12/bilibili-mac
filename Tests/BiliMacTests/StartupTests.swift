import Foundation
import Testing
@testable import BiliMac

@Suite(.serialized) @MainActor struct StartupTests {
    @Test func packagedAppUsesItsExistingStandardDomain() {
        var suiteRequested = false
        let defaults = AppSettings.makeDefaults(bundleIdentifier: AppSettings.domain, suiteFactory: { _ in
            suiteRequested = true
            return nil
        })
        #expect(defaults === UserDefaults.standard)
        #expect(!suiteRequested)
    }
    @Test func unavailableSuiteFallsBackWithoutCrashing() {
        let defaults = AppSettings.makeDefaults(bundleIdentifier: "unit.test.host", suiteFactory: { _ in nil })
        #expect(defaults === UserDefaults.standard)
    }
    @Test func alternateHostKeepsTheAppPreferencesDomain() throws {
        let name = "dev.zzpp.BiliMac.tests.\(UUID().uuidString)"
        let isolated = try #require(UserDefaults(suiteName: name))
        defer { isolated.removePersistentDomain(forName: name) }
        var requestedDomain: String?
        let defaults = AppSettings.makeDefaults(bundleIdentifier: "unit.test.host", suiteFactory: { domain in
            requestedDomain = domain
            return isolated
        })
        #expect(requestedDomain == AppSettings.domain)
        #expect(defaults === isolated)
    }
    @Test func appStoreCanInitializeBeforeAnyNetworkOrLogin() {
        let store = AppStore()
        #expect(!store.loading)
        #expect(store.player.player.currentItem == nil)
        #expect(!store.showPlayer)
        store.player.stop()
    }
}
