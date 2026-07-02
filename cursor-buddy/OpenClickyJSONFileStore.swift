//
//  OpenClickyJSONFileStore.swift
//  OpenClicky
//
//  Shared helpers for OpenClicky's small JSON-file-backed stores. Several
//  stores previously hand-rolled the same "resolve Application Support
//  directory (with home-directory fallback), create it, encode/decode JSON
//  atomically" boilerplate. Centralized here so new stores don't repeat it.
//

import Foundation

enum OpenClickyJSONFileStore {
    /// The user's Application Support directory, falling back to
    /// ~/Library/Application Support if FileManager can't resolve it.
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// The shared "OpenClicky" directory under Application Support, with an
    /// optional relative subpath appended (e.g. ["Logs"], ["agents"]).
    static func openClickyDirectory(fileManager: FileManager = .default, subpath: [String] = []) -> URL {
        var url = applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("OpenClicky", isDirectory: true)
        for component in subpath {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        return url
    }

    @discardableResult
    static func ensureDirectoryExists(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var defaultDecoder: JSONDecoder {
        JSONDecoder()
    }

    /// Encodes `value` and writes it atomically to `fileURL`, creating the
    /// parent directory first.
    static func write<T: Encodable>(
        _ value: T,
        to fileURL: URL,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = OpenClickyJSONFileStore.defaultEncoder
    ) throws {
        try ensureDirectoryExists(fileURL.deletingLastPathComponent(), fileManager: fileManager)
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Decodes `T` from `fileURL`, returning `nil` if the file is missing or
    /// decoding fails.
    static func read<T: Decodable>(
        _ type: T.Type,
        from fileURL: URL,
        fileManager: FileManager = .default,
        decoder: JSONDecoder = OpenClickyJSONFileStore.defaultDecoder
    ) -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
