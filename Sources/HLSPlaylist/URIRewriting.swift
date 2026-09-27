import Foundation

/// The role of a URI inside a playlist, passed to URI transforms.
public enum URIRole: Sendable, Hashable {
    case variant
    case iFrameVariant
    case rendition
    case segment
    case partialSegment
    case initializationSection
    case key
    case sessionData
    case preloadHint
    case renditionReport
}

extension MultivariantPlaylist {
    /// Returns a copy with every URI transformed, e.g. to route requests
    /// through a local proxy or to append authentication tokens.
    public func mapURIs(_ transform: (String, URIRole) throws -> String) rethrows -> MultivariantPlaylist {
        var copy = self
        for index in copy.variants.indices {
            copy.variants[index].uri = try transform(copy.variants[index].uri, .variant)
        }
        for index in copy.iFrameVariants.indices {
            copy.iFrameVariants[index].uri = try transform(copy.iFrameVariants[index].uri, .iFrameVariant)
        }
        for index in copy.renditions.indices {
            if let uri = copy.renditions[index].uri { copy.renditions[index].uri = try transform(uri, .rendition) }
        }
        for index in copy.sessionData.indices {
            if let uri = copy.sessionData[index].uri { copy.sessionData[index].uri = try transform(uri, .sessionData) }
        }
        for index in copy.sessionKeys.indices {
            if let uri = copy.sessionKeys[index].uri { copy.sessionKeys[index].uri = try transform(uri, .key) }
        }
        return copy
    }

    /// Returns a copy with relative URIs made absolute against `baseURL`.
    public func resolvingURIs(against baseURL: URL) -> MultivariantPlaylist {
        mapURIs { uri, _ in resolve(uri, against: baseURL) }
    }
}

extension MediaPlaylist {
    /// Returns a copy with every URI transformed, e.g. to route requests
    /// through a local proxy or to append authentication tokens.
    public func mapURIs(_ transform: (String, URIRole) throws -> String) rethrows -> MediaPlaylist {
        var copy = self
        // Keys and maps are shared by many segments; transform each distinct value once.
        var keyCache: [EncryptionKey: EncryptionKey] = [:]
        var mapCache: [MediaInitializationSection: MediaInitializationSection] = [:]
        func mapKey(_ key: EncryptionKey) throws -> EncryptionKey {
            if let cached = keyCache[key] { return cached }
            var mapped = key
            if let uri = key.uri { mapped.uri = try transform(uri, .key) }
            keyCache[key] = mapped
            return mapped
        }
        func mapMap(_ section: MediaInitializationSection) throws -> MediaInitializationSection {
            if let cached = mapCache[section] { return cached }
            var mapped = section
            mapped.uri = try transform(section.uri, .initializationSection)
            mapCache[section] = mapped
            return mapped
        }
        func mapParts(_ parts: [PartialSegment]) throws -> [PartialSegment] {
            try parts.map { part in
                var part = part
                part.uri = try transform(part.uri, .partialSegment)
                return part
            }
        }

        for index in copy.segments.indices {
            var segment = copy.segments[index]
            segment.uri = try transform(segment.uri, .segment)
            segment.keys = try segment.keys.map(mapKey)
            segment.map = try segment.map.map(mapMap)
            segment.parts = try mapParts(segment.parts)
            copy.segments[index] = segment
        }
        copy.trailingParts = try mapParts(copy.trailingParts)
        for index in copy.preloadHints.indices {
            copy.preloadHints[index].uri = try transform(copy.preloadHints[index].uri, .preloadHint)
        }
        for index in copy.renditionReports.indices {
            copy.renditionReports[index].uri = try transform(copy.renditionReports[index].uri, .renditionReport)
        }
        return copy
    }

    /// Returns a copy with relative URIs made absolute against `baseURL`.
    public func resolvingURIs(against baseURL: URL) -> MediaPlaylist {
        mapURIs { uri, _ in resolve(uri, against: baseURL) }
    }

    /// Absolute URLs of every segment, resolved against `baseURL`.
    public func segmentURLs(relativeTo baseURL: URL) -> [URL] {
        segments.compactMap { URL(string: $0.uri, relativeTo: baseURL)?.absoluteURL }
    }
}

extension Playlist {
    /// Returns a copy with every URI transformed.
    public func mapURIs(_ transform: (String, URIRole) throws -> String) rethrows -> Playlist {
        switch self {
        case .multivariant(let playlist): .multivariant(try playlist.mapURIs(transform))
        case .media(let playlist): .media(try playlist.mapURIs(transform))
        }
    }

    /// Returns a copy with relative URIs made absolute against `baseURL`.
    public func resolvingURIs(against baseURL: URL) -> Playlist {
        mapURIs { uri, _ in resolve(uri, against: baseURL) }
    }
}

private func resolve(_ uri: String, against baseURL: URL) -> String {
    URL(string: uri, relativeTo: baseURL)?.absoluteURL.absoluteString ?? uri
}
