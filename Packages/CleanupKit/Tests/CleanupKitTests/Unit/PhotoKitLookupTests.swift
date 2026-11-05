import Photos
import Testing

@testable import CleanupKit

/// A fetch of photos that leaves out `includeAllBurstAssets` returns only the one frame of a burst that
/// Photos shows. The scan sees every frame, so a look-up by identifier that does not would find the key
/// photo again and nothing else: the other frames would get no thumbnail, no preview, no size, and the
/// removal of a burst would not reach them.
@Suite struct PhotoKitLookupTests {
    @Test func aLookUpSeesEveryFrameOfABurst() {
        #expect(PhotoKitLibrary.lookupOptions().includeAllBurstAssets)
    }

    @Test func aLookUpSeesOnlyThePersonsOwnLibrary() {
        #expect(PhotoKitLibrary.lookupOptions().includeAssetSourceTypes == [.typeUserLibrary])
    }

    @Test func eachLookUpGetsOptionsOfItsOwn() {
        // The full enumeration adds a sort order to what it is given; that must not leak into the next look-up.
        let first = PhotoKitLibrary.lookupOptions()
        first.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        #expect(PhotoKitLibrary.lookupOptions().sortDescriptors == nil)
    }
}
