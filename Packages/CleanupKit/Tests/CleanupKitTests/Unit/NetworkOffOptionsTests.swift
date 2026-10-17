import Testing

@testable import CleanupKit

@Suite struct NetworkOffOptionsTests {
    @Test func imageOptionsNeverAllowNetwork() {
        for mode in [PHImageRequestOptionsDeliveryModeAlias.highQualityFormat, .fastFormat, .opportunistic] {
            #expect(NetworkOffOptions.image(deliveryMode: mode).isNetworkAccessAllowed == false)
        }
    }

    @Test func resourceOptionsNeverAllowNetwork() {
        #expect(NetworkOffOptions.resource().isNetworkAccessAllowed == false)
    }

    @Test func videoOptionsNeverAllowNetwork() {
        #expect(NetworkOffOptions.video().isNetworkAccessAllowed == false)
    }
}

import Photos
typealias PHImageRequestOptionsDeliveryModeAlias = PHImageRequestOptionsDeliveryMode
