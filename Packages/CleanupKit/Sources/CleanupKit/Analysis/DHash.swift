import CoreGraphics

/// 64-bit difference hash: grayscale 9×8, compare each pixel with its right
/// neighbour. Tolerant of resizing, recompression and format changes (research R3).
public func dHash(_ image: CGImage) -> UInt64 {
    guard let gray = GrayImage(image, width: 9, height: 8) else { return 0 }
    var hash: UInt64 = 0
    for y in 0..<8 {
        for x in 0..<8 {
            hash <<= 1
            if gray[x, y] > gray[x + 1, y] { hash |= 1 }
        }
    }
    return hash
}

public func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
    (a ^ b).nonzeroBitCount
}
