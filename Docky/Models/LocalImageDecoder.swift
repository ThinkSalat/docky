//
//  LocalImageDecoder.swift
//  Docky
//
//  Bounded, eager local-image decoding for user and theme artwork.
//

import AppKit
import Darwin
import Foundation
import ImageIO

nonisolated final class DecodedLocalImage: @unchecked Sendable {
    let image: NSImage
    let cgImage: CGImage
    let decodedByteCost: Int

    init(
        image: NSImage,
        cgImage: CGImage,
        decodedByteCost: Int
    ) {
        self.image = image
        self.cgImage = cgImage
        self.decodedByteCost = decodedByteCost
    }
}

nonisolated enum LocalImageDecoder {
    static let maximumEncodedBytes = 50 * 1_024 * 1_024
    static let maximumDimension = 16_384
    static let maximumPixelCount = 32 * 1_024 * 1_024

    static func decode(
        at url: URL,
        maximumEncodedBytes: Int = maximumEncodedBytes,
        maximumDimension: Int = maximumDimension,
        maximumPixelCount: Int = maximumPixelCount
    ) -> DecodedLocalImage? {
        guard url.isFileURL,
              pathContainsNoSymbolicLink(url) else {
            return nil
        }

        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_size > 0,
              fileInfo.st_size <= maximumEncodedBytes else {
            return nil
        }

        guard let data = readAll(
            descriptor: descriptor,
            expectedBytes: Int(fileInfo.st_size),
            maximumBytes: maximumEncodedBytes
        ) else {
            return nil
        }
        return decode(
            data: data,
            maximumEncodedBytes: maximumEncodedBytes,
            maximumDimension: maximumDimension,
            maximumPixelCount: maximumPixelCount
        )
    }

    static func decode(
        data: Data,
        maximumEncodedBytes: Int = maximumEncodedBytes,
        maximumDimension: Int = maximumDimension,
        maximumPixelCount: Int = maximumPixelCount
    ) -> DecodedLocalImage? {
        guard !data.isEmpty,
              data.count <= maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ), CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .intValue,
              width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumPixelCount / height else {
            return nil
        }

        let options: CFDictionary = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            options
        ) else {
            return nil
        }

        let decodedCost = cgImage.bytesPerRow.multipliedReportingOverflow(
            by: cgImage.height
        )
        guard !decodedCost.overflow else { return nil }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return DecodedLocalImage(
            image: image,
            cgImage: cgImage,
            decodedByteCost: decodedCost.partialValue
        )
    }

    private static func pathContainsNoSymbolicLink(_ url: URL) -> Bool {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &resolved) != nil else {
            return false
        }
        // Compare against the caller's lexical path. Foundation's
        // `standardizedFileURL` rewrites canonical macOS paths such as
        // `/private/tmp` back to the public `/tmp` symlink, which would
        // incorrectly reject an already-canonical path. Any real symlink
        // (or noncanonical `.` / `..` traversal) still changes `realpath`
        // and therefore fails closed here.
        return String(cString: resolved) == url.path
    }

    private static func readAll(
        descriptor: Int32,
        expectedBytes: Int,
        maximumBytes: Int
    ) -> Data? {
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return data.count == expectedBytes ? data : nil
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }

            guard data.count <= maximumBytes - count else {
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
