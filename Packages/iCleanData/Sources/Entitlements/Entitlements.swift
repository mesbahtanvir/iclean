import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(Security)
import Security
#endif

/// Entitlement + allowance seam (APP_PLATFORM.md §4). The free allowance is
/// the ENTIRE first cleanup session (~100 items), so the trust loop completes
/// before the gate ever appears (DESIGN.md §2).
public protocol EntitlementsProviding: Sendable {
    var isUnlocked: Bool { get async }
    var lifetimeCommittedCount: Int { get async }
    func recordCommitted(count: Int) async
    /// Items still committable for free (Int.max when unlocked).
    func freeRemaining() async -> Int
}

public enum Allowance {
    /// ~ one training-wheels session (DESIGN.md §9.5).
    public static let freeItemLimit = 100
}

// MARK: - Keychain-backed counter (survives delete/reinstall — APP_PLATFORM.md §4.3)

public struct KeychainCounter: Sendable {
    private let account: String

    public init(account: String = "com.iclean.lifetimeCommitted") {
        self.account = account
    }

    public func read() -> Int {
        #if canImport(Security)
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              let value = Int(string)
        else { return 0 }
        return value
        #else
        return UserDefaults.standard.integer(forKey: account)
        #endif
    }

    public func write(_ value: Int) {
        #if canImport(Security)
        let data = Data(String(value).utf8)
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
        #else
        UserDefaults.standard.set(value, forKey: account)
        #endif
    }

    #if canImport(Security)
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "com.iclean.entitlements",
        ]
    }
    #endif
}

// MARK: - StoreKit 2 implementation

#if canImport(StoreKit)
/// One non-consumable, Family Sharing enabled in App Store Connect —
/// currentEntitlements then includes family transactions automatically.
public actor StoreEntitlements: EntitlementsProviding {
    public static let productId = "com.iclean.unlock.lifetime"

    private let counter = KeychainCounter()
    private let unlockCache = KeychainCounter(account: "com.iclean.unlocked")
    private var cachedUnlocked: Bool
    private var updatesTask: Task<Void, Never>?

    public init() {
        // Keychain cache keeps offline devices unlocked (APP_PLATFORM.md §4.2).
        cachedUnlocked = KeychainCounter(account: "com.iclean.unlocked").read() == 1
    }

    /// Start at app launch, before any UI.
    public func startListening() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refreshFromCurrentEntitlements() }
    }

    public var isUnlocked: Bool { cachedUnlocked }

    public var lifetimeCommittedCount: Int { counter.read() }

    public func recordCommitted(count: Int) {
        counter.write(counter.read() + count)
    }

    public func freeRemaining() -> Int {
        if cachedUnlocked { return .max }
        return max(0, Allowance.freeItemLimit - counter.read())
    }

    public func purchase() async throws -> Bool {
        guard let product = try await Product.products(for: [Self.productId]).first else {
            return false
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            // Accept only verified transactions (APP_PLATFORM.md §4.2).
            guard case .verified(let transaction) = verification else { return false }
            await transaction.finish()
            setUnlocked(true)
            return true
        default:
            return false
        }
    }

    public func restore() async {
        try? await AppStore.sync()
        await refreshFromCurrentEntitlements()
    }

    private func refreshFromCurrentEntitlements() async {
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productID == Self.productId,
                  transaction.revocationDate == nil // refunds clear the cache
            else { continue }
            unlocked = true
        }
        setUnlocked(unlocked)
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update,
              transaction.productID == Self.productId
        else { return }
        setUnlocked(transaction.revocationDate == nil)
        await transaction.finish()
    }

    private func setUnlocked(_ value: Bool) {
        cachedUnlocked = value
        unlockCache.write(value ? 1 : 0)
    }
}
#endif

/// Test/preview stand-in.
public actor FixedEntitlements: EntitlementsProviding {
    private var unlocked: Bool
    private var committed: Int

    public init(unlocked: Bool, committed: Int = 0) {
        self.unlocked = unlocked
        self.committed = committed
    }

    public var isUnlocked: Bool { unlocked }
    public var lifetimeCommittedCount: Int { committed }
    public func recordCommitted(count: Int) { committed += count }
    public func freeRemaining() -> Int {
        unlocked ? .max : max(0, Allowance.freeItemLimit - committed)
    }
    public func setUnlocked(_ value: Bool) { unlocked = value }
}
