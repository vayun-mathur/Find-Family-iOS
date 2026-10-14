import AppIntents
import Foundation

// MARK: - Link expiry

/// Expiry choices for a share link. Same durations as the in-app Add Link dialog
/// (which mirrors Android `intents/CreateLinkIntent.kt`), exposed as an AppEnum
/// so Shortcuts shows a picker instead of a free-form number.
enum LinkExpiry: String, AppEnum {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case sixHours
    case twelveHours
    case oneDay
    case twoDays
    case oneWeek

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Link expiry")
    }

    static var caseDisplayRepresentations: [LinkExpiry: DisplayRepresentation] {
        [
            .fifteenMinutes: DisplayRepresentation(title: "15 minutes"),
            .thirtyMinutes: DisplayRepresentation(title: "30 minutes"),
            .oneHour: DisplayRepresentation(title: "1 hour"),
            .twoHours: DisplayRepresentation(title: "2 hours"),
            .fourHours: DisplayRepresentation(title: "4 hours"),
            .sixHours: DisplayRepresentation(title: "6 hours"),
            .twelveHours: DisplayRepresentation(title: "12 hours"),
            .oneDay: DisplayRepresentation(title: "1 day"),
            .twoDays: DisplayRepresentation(title: "2 days"),
            .oneWeek: DisplayRepresentation(title: "1 week"),
        ]
    }

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .twelveHours: return 12 * 60 * 60
        case .oneDay: return 24 * 60 * 60
        case .twoDays: return 2 * 24 * 60 * 60
        case .oneWeek: return 7 * 24 * 60 * 60
        }
    }
}

// MARK: - Family member entity

/// One family member's latest known location. Mirrors Android
/// `library.intents.findfamily.FamilyMemberData(name, locationName, lat, lon)`.
/// A missing fix reports 0.0/0.0, exactly like Android's `?: 0.0` fallback.
struct FamilyMember: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Family member")
    }

    static var defaultQuery = FamilyMemberQuery()

    var id: String
    var name: String
    var place: String
    var lat: Double
    var lon: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(place)")
    }

    /// Every known user with their latest fix. Mirrors Android `GetIntent`'s
    /// `getAllUsers()` + `latestLocationsOnce()` join (self included, like Android).
    static func all() -> [FamilyMember] {
        let latest = Database.shared.latestLocationsSubject.value
        return Database.shared.usersSubject.value.map { user in
            let loc = latest[user.id]
            return FamilyMember(
                id: String(user.id),
                name: user.name,
                place: user.locationName,
                lat: loc?.coord.lat ?? 0.0,
                lon: loc?.coord.lon ?? 0.0
            )
        }
    }
}

struct FamilyMemberQuery: EntityQuery {
    func entities(for identifiers: [FamilyMember.ID]) async throws -> [FamilyMember] {
        FamilyMember.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FamilyMember] {
        FamilyMember.all()
    }
}

// MARK: - Create share link

/// Thrown when the post-quantum native lib is not linked, so no link key can
/// be generated. Surfaced to Shortcuts as a spoken/displayed failure.
enum ShareLinkError: Error, CustomLocalizedStringResourceConvertible {
    case keyUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .keyUnavailable:
            return "Couldn't create the link — encryption isn't available on this build."
        }
    }
}

/// Siri/App Shortcuts entry point that mints a FindFamily location-sharing link.
/// Mirrors Android `intents/CreateLinkIntent.kt`: generate an ML-KEM link key,
/// persist a `TemporaryLink` (the background tick then publishes encrypted
/// location for it until it expires), and return the same recipient URL the
/// in-app copy button produces (`/view/<base26>#s=<seed>`).
struct CreateShareLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Create share link"
    static var description = IntentDescription(
        "Creates a FindFamily link that shares your location until it expires."
    )
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Create share link for \(\.$name)")
    }

    @Parameter(title: "Label", description: "A label to tell links apart.")
    var name: String

    @Parameter(title: "Expiry", default: .oneHour)
    var expiry: LinkExpiry

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw $name.needsValueError("Give the link a label so you can tell it apart later.")
        }
        // Links are post-quantum only with no classic fallback: a PQC keygen failure
        // (native lib not linked) fails the call rather than handing back a link
        // that can never publish — same contract as Android `CreateLinkIntent`.
        let linkKey: (seedB64Url: String, publicB64: String)
        do {
            linkKey = try PQCKeyManager.shared.generateLinkKey()
        } catch {
            throw ShareLinkError.keyUnavailable
        }
        // Random 64-bit id in the userid namespace (mirrors `newTemporaryLinkId`);
        // routing goes through the explicit-id INSERT OR REPLACE.
        let link = TemporaryLink(
            id: Int64.random(in: 1...Int64.max),
            name: label,
            key: "",
            publicKey: "",
            deleteAt: Date().addingTimeInterval(expiry.seconds),
            pqcPublicKey: linkKey.publicB64,
            pqcKey: nil,
            pqcSeed: linkKey.seedB64Url
        )
        let stored = Database.shared.upsertTemporaryLink(link)
        // Must match the URL format the in-app copy button produces.
        let url = "https://findfamily.cc/view/\(Base26.encode(stored.id))#s=\(linkKey.seedB64Url)"
        return .result(
            value: url,
            dialog: "Share link for \(label) created. It expires \(expiryString)."
        )
    }

    private var expiryString: String {
        switch expiry {
        case .fifteenMinutes: return "in 15 minutes"
        case .thirtyMinutes: return "in 30 minutes"
        case .oneHour: return "in 1 hour"
        case .twoHours: return "in 2 hours"
        case .fourHours: return "in 4 hours"
        case .sixHours: return "in 6 hours"
        case .twelveHours: return "in 12 hours"
        case .oneDay: return "in 1 day"
        case .twoDays: return "in 2 days"
        case .oneWeek: return "in 1 week"
        }
    }
}

// MARK: - Get family locations

/// Siri/App Shortcuts entry point returning every family member's latest known
/// location. Mirrors Android `intents/GetIntent.kt`.
struct GetFamilyLocationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get family locations"
    static var description = IntentDescription(
        "Returns the latest known location of each family member."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<[FamilyMember]> {
        let members = FamilyMember.all()
        return .result(
            value: members,
            dialog: members.isEmpty
                ? "No family members yet."
                : "Found \(members.count) family member\(members.count == 1 ? "" : "s")."
        )
    }
}
