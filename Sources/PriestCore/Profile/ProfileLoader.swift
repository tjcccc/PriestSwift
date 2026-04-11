import Foundation

/// Protocol for loading profiles by name.
///
/// Profile loading is synchronous — filesystem reads are fast and do not benefit
/// from async. The engine is handed a resolved Profile and does not access the
/// filesystem again after loading.
public protocol ProfileLoader: Sendable {
    /// Load the profile with the given name.
    /// - Throws: `PriestError` with code `.profileNotFound` if not found.
    func load(_ name: String) throws -> Profile
}
