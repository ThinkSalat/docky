import Foundation
import XCTest

final class LocalImageDecoderTests: XCTestCase {
    func testValidImageIsEagerlyDecodedWithBoundedCost() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let imageURL = fixture.appendingPathComponent("pixel.png")
        try pngData.write(to: imageURL)

        let decoded = try XCTUnwrap(LocalImageDecoder.decode(at: imageURL))
        XCTAssertEqual(decoded.image.size.width, 1)
        XCTAssertEqual(decoded.image.size.height, 1)
        XCTAssertGreaterThan(decoded.decodedByteCost, 0)
    }

    func testEncodedAndDecodedBoundsFailClosed() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let imageURL = fixture.appendingPathComponent("pixel.png")
        try pngData.write(to: imageURL)

        XCTAssertNil(
            LocalImageDecoder.decode(
                at: imageURL,
                maximumEncodedBytes: 4
            )
        )
        XCTAssertNil(
            LocalImageDecoder.decode(
                at: imageURL,
                maximumPixelCount: 0
            )
        )
    }

    func testInMemoryArtworkUsesTheSameDecodeBounds() throws {
        let decoded = try XCTUnwrap(
            LocalImageDecoder.decode(data: pngData)
        )
        XCTAssertEqual(decoded.image.size.width, 1)
        XCTAssertEqual(decoded.image.size.height, 1)
        XCTAssertNil(
            LocalImageDecoder.decode(
                data: pngData,
                maximumEncodedBytes: 4
            )
        )
        XCTAssertNil(
            LocalImageDecoder.decode(
                data: Data(),
                maximumEncodedBytes: 4
            )
        )
    }

    func testDirectoriesAndSymbolicLinksAreRejected() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let imageURL = fixture.appendingPathComponent("pixel.png")
        let linkURL = fixture.appendingPathComponent("linked.png")
        try pngData.write(to: imageURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: imageURL
        )

        XCTAssertNil(LocalImageDecoder.decode(at: fixture))
        XCTAssertNil(LocalImageDecoder.decode(at: linkURL))
    }

    func testSymbolicLinkInParentPathIsRejected() throws {
        let fixture = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let realDirectory = fixture.appendingPathComponent(
            "real",
            isDirectory: true
        )
        let linkedDirectory = fixture.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try pngData.write(
            to: realDirectory.appendingPathComponent("pixel.png")
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )

        XCTAssertNil(
            LocalImageDecoder.decode(
                at: linkedDirectory.appendingPathComponent("pixel.png")
            )
        )
    }

    private var pngData: Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC" +
                "AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }

    private func temporaryDirectory() -> URL {
        // Foundation intentionally preserves `/var` when resolving the
        // process temporary directory even though libc `realpath` exposes
        // its canonical `/private/var` location. Use the canonical macOS
        // temporary root so the positive case does not contradict the
        // decoder's explicit no-symlink input policy.
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "docky-local-image-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }
}
