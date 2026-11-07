import Foundation

/// Per-project signing options consumed by PersonalCertificateSigner.sign.
struct PersonalProjectOptions: Sendable {
    var displayName: String? = nil
    var bundleID: String? = nil
    var version: String? = nil
    var outputFilename: String = "Mirsa-Signed"
    var fileSharing = false
    var removeURLSchemes = false
    var removeEmbeddedProfile = false
    var removeWatchApp = false
    var minimumOS: String? = nil
    var libraries: [URL] = []
    var additionalProfiles: [Data] = []
    var removeExtensions = false
    var removeAppClips = false
    var gameMode: PersonalGameMode = .keep
    var fixWhiteIcon = false
    var newTweaksFirst = false
    var useLoader = false
    var customEntitlements: Data? = nil
    var exportExtension = "ipa"
}

enum PersonalGameMode: String, Codable, CaseIterable, Sendable { case keep, on, off }

func personalText(_ en: String, _ ar: String) -> String { L.isArabic ? ar : en }

/// Editable values persisted per library app. Library files are referenced by id,
/// never by absolute path.
struct PersonalProjectDraft: Codable, Equatable {
    var name = ""
    var bundleID = ""
    var version = ""
    var outputFilename = ""
    var fileSharing = false
    var removeURLSchemes = false
    var removeEmbeddedProfile = false
    var removeWatchApp = false
    var minimumOS = ""
    var tweakIDs: [UUID] = []
    var removeExtensions: Bool? = nil
    var removeAppClips: Bool? = nil
    var additionalProfileIDs: [String]? = nil
    var gameMode: PersonalGameMode? = nil
    var fixWhiteIcon: Bool? = nil
    var fixDarkIcon: Bool? = nil
    var newTweaksFirst: Bool? = nil
    var workspaceNote: String? = nil
    var exportExtension: String? = nil
    var customEntitlements: Data? = nil
    var customEntitlementsName: String? = nil
    var directInjection: Bool? = nil
    /// tweak id -> target id. nil/absent = main executable. Specific framework/extension targets stay disabled until the backend enumerates real Mach-O targets.
    var tweakTargets: [String: String]? = nil
    /// Excluded package components, keyed "<tweakUUID>:<rootRelativePath>". A .deb exposes each dylib/framework root as its own component.
    var excludedRoots: [String]? = nil
    var appliedTweakIDs: [UUID]? = nil
}
