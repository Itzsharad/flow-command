import AppKit
import CryptoKit
import Foundation
import IOKit

/// Your plan: a 14-day Pro trial, then Free (15 AI tasks a week) or Pro (unlimited).
/// The usage server keeps the count, so reinstalling doesn't reset it. Nothing you say or see is sent to it — only counts.
final class Account: ObservableObject {
    static let shared = Account()

    enum Plan: String { case unknown, trial, free, pro }

    @Published private(set) var plan: Plan
    @Published private(set) var used = 0
    @Published private(set) var limit: Int?
    @Published private(set) var trialEndsAt: Date?
    @Published private(set) var resetsAt: Date?
    @Published private(set) var hasLicense = false

    static let freeWeekly = 15
    static let freeRoutines = 3
    static let freeStyles: Set<String> = ["classic", "kitty", "pup", "galaxy"]

    private let d = UserDefaults.standard

    init() {
        plan = Plan(rawValue: UserDefaults.standard.string(forKey: "plan") ?? "") ?? .unknown
        used = d.integer(forKey: "planUsed")
        limit = d.object(forKey: "planLimit") as? Int
        hasLicense = d.bool(forKey: "hasLicense")
        if let t = d.object(forKey: "trialEndsAt") as? Double { trialEndsAt = Date(timeIntervalSince1970: t) }
        if let t = d.object(forKey: "resetsAt") as? Double { resetsAt = Date(timeIntervalSince1970: t) }
    }

    // MARK: Configuration (filled in by the build)

    static func configURL(_ key: String) -> URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: s.trimmingCharacters(in: .whitespaces))
    }
    static var serverURL: URL? { configURL("FCServerURL") }
    static var checkoutURL: URL? { configURL("FCCheckoutURL") }
    /// Before the usage server exists, the app works as before (bring your own key, no limits).
    static var serverEnabled: Bool { serverURL != nil }

    // MARK: What the plan allows

    /// Pro features: during the trial, with a license, or when no server is set up yet.
    var isPro: Bool { !Account.serverEnabled || plan == .pro || plan == .trial || plan == .unknown }
    var left: Int? { plan == .free ? max(0, (limit ?? Account.freeWeekly) - used) : nil }
    var outOfTasks: Bool { (left ?? 1) <= 0 }

    func allowedStyle(_ key: String) -> String { Account.styleAllowed(key, pro: isPro) ? key : "galaxy" }
    static func styleAllowed(_ key: String, pro: Bool) -> Bool { pro || freeStyles.contains(key) }
    var lockedStyles: [String] { isPro ? [] : PanelHTML.styles.map(\.key).filter { !Account.freeStyles.contains($0) } }

    var summary: String { Account.summary(plan: plan, used: used, limit: limit, trialEndsAt: trialEndsAt, serverEnabled: Account.serverEnabled) }

    static func summary(plan: Plan, used: Int, limit: Int?, trialEndsAt: Date?, serverEnabled: Bool, now: Date = Date()) -> String {
        guard serverEnabled else { return "Unlimited (setup mode)" }
        switch plan {
        case .pro: return "Pro: unlimited AI tasks"
        case .trial:
            let days = max(1, Int(ceil((trialEndsAt ?? now).timeIntervalSince(now) / 86400)))
            return "Pro trial: \(days) day\(days == 1 ? "" : "s") left"
        case .free:
            let l = limit ?? freeWeekly
            return "\(max(0, l - used)) of \(l) free AI tasks left this week"
        case .unknown: return "Checking your plan…"
        }
    }

    // MARK: This computer

    /// An anonymous id for this computer (a one-way hash; the real hardware id never leaves the Mac).
    lazy var deviceID: String = {
        var raw = ""
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            if let v = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { raw = v }
            IOObjectRelease(service)
        }
        if raw.isEmpty {
            raw = d.string(forKey: "fallbackDeviceID") ?? UUID().uuidString
            d.set(raw, forKey: "fallbackDeviceID")
        }
        return Account.hash("flowcommand-device:" + raw)
    }()

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var licenseKey: String? { Keychain.get("license") }

    // MARK: Talking to the server

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let base = Account.serverURL else { throw NSError(domain: "FC", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not set up yet."]) }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (resp as? HTTPURLResponse)?.statusCode != 200 {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Something went wrong. Try again."
            throw NSError(domain: "FC", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return obj
    }

    func refresh() async {
        guard Account.serverEnabled, let obj = try? await post("v1/status", ["device": deviceID]) else { return }
        apply(obj)
    }

    /// Returns nil when the key worked, or a message to show.
    func activate(_ key: String) async -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "Paste your license key first." }
        do {
            let obj = try await post("v1/license", ["device": deviceID, "license": k, "name": Host.current().localizedName ?? "Mac"])
            Keychain.set(k, account: "license")
            onMain { self.hasLicense = true; self.d.set(true, forKey: "hasLicense") }
            apply(obj)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Frees this computer's seat so the license can be used on another one.
    func removeLicense() async {
        if let k = licenseKey { _ = try? await post("v1/license", ["device": deviceID, "license": k, "remove": true]) }
        Keychain.delete("license")
        onMain { self.hasLicense = false; self.d.set(false, forKey: "hasLicense") }
        await refresh()
    }

    private func apply(_ obj: [String: Any]) {
        let p = Plan(rawValue: obj["plan"] as? String ?? "") ?? .unknown
        let u = (obj["used"] as? NSNumber)?.intValue ?? 0
        let l = (obj["limit"] as? NSNumber)?.intValue
        let t = (obj["trialEndsAt"] as? NSNumber)?.doubleValue
        let r = (obj["resetsAt"] as? NSNumber)?.doubleValue
        set(plan: p, used: u, limit: l, trial: t, resets: r)
    }

    /// The server also reports the plan on every AI reply.
    func update(from http: HTTPURLResponse) {
        guard let p = http.value(forHTTPHeaderField: "x-fc-plan"), let plan = Plan(rawValue: p) else { return }
        let num: (String) -> Double? = { Double(http.value(forHTTPHeaderField: $0) ?? "") }
        set(plan: plan, used: Int(num("x-fc-used") ?? 0), limit: num("x-fc-limit").map { Int($0) },
            trial: num("x-fc-trial-ends"), resets: num("x-fc-resets"))
    }

    private func set(plan p: Plan, used u: Int, limit l: Int?, trial t: Double?, resets r: Double?) {
        onMain {
            self.plan = p; self.used = u; self.limit = l
            self.trialEndsAt = t.map { Date(timeIntervalSince1970: $0) }
            self.resetsAt = r.map { Date(timeIntervalSince1970: $0) }
            self.d.set(p.rawValue, forKey: "plan"); self.d.set(u, forKey: "planUsed")
            if let l = l { self.d.set(l, forKey: "planLimit") } else { self.d.removeObject(forKey: "planLimit") }
            if let t = t { self.d.set(t, forKey: "trialEndsAt") } else { self.d.removeObject(forKey: "trialEndsAt") }
            if let r = r { self.d.set(r, forKey: "resetsAt") }
            // a Free plan can't keep a Pro buddy or world
            let s = AppSettings.shared
            if !self.isPro, !Account.freeStyles.contains(s.popupStyle) { s.popupStyle = "galaxy" }
        }
    }

    func openUpgrade() {
        if let url = Account.checkoutURL { NSWorkspace.shared.open(url) } else { AppDelegate.shared?.showMain() }
    }
}
