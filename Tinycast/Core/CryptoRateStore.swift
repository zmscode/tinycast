import Foundation

/// Downloads, caches and periodically refreshes coin prices, so the calculator can answer
/// `1 btc in usd`. Deliberately a separate store from `CurrencyRateStore` rather than a second
/// endpoint inside it: it is a *different provider*, and the invariant is that a networked feature
/// is opt-in behind a toggle whose dialog names its provider. Folding coins into the fiat consent
/// would silently start talking to CoinGecko for anyone who had only ever agreed to Frankfurter.
///
/// Structure mirrors `CurrencyRateStore` — same four consent guards, same cacheless session, same
/// persisted-snapshot refresh loop. Read that one first; the differences are noted below.
@MainActor
final class CryptoRateStore: ObservableObject {
	/// CoinGecko's public API — no key, no account. Only the coins in `CryptoData.generated.swift`
	/// are ever requested, and that file is generated from this same feed, so the table can never
	/// list a coin the app can't price.
	static let provider = "CoinGecko"
	static let providerURL = URL(string: "https://www.coingecko.com")!

	/// Hourly, unlike fiat's daily: central banks republish once a day, coins move constantly, and a
	/// day-old quote would be actively misleading rather than merely stale.
	static let refreshInterval: TimeInterval = 3600
	private static let retryInterval: TimeInterval = 10 * 60

	/// Priced in USD to match `CurrencyRateStore`'s base, so the two tables merge without a
	/// cross-rate hop that would compound both feeds' rounding.
	nonisolated static let base = "USD"

	@Published private(set) var isEnabled: Bool

	/// Coin rates quoted the same way as fiat — units per 1 `base` — so a merged table needs no
	/// special cases in `CurrencyRates.convert`.
	@Published private(set) var rates: CurrencyRates?

	private static let consentKey = "cryptoRatesEnabled"
	private let defaults = UserDefaults.standard
	private let fileURL: URL
	private var pump: Task<Void, Never>?

	init() {
		isEnabled = defaults.bool(forKey: Self.consentKey)
		let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
		let base = FileManager.default
			.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent(bundleID, isDirectory: true)
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		fileURL = base.appendingPathComponent("crypto-rates.json")

		// Guard 1 — a disabled feature doesn't read back a snapshot left on disk.
		guard isEnabled, let data = try? Data(contentsOf: fileURL) else { return }
		rates = try? JSONDecoder().decode(CurrencyRates.self, from: data)
	}

	/// Guard 2 — the read path. Nil without consent, so the merge below contributes nothing.
	var available: CurrencyRates? { isEnabled ? rates : nil }

	/// Guard 3 — no consent, no loop, so `AppCore.start()` can call this unconditionally.
	func start() {
		guard isEnabled else { return }
		pump?.cancel()
		pump = Task { [weak self] in
			while !Task.isCancelled, let self, self.isEnabled {
				let age = max(
					0, self.rates.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity)
				guard age >= Self.refreshInterval else {
					try? await Task.sleep(for: .seconds(Self.refreshInterval - age))
					continue
				}
				let ok = await self.fetchAndStore()
				try? await Task.sleep(for: .seconds(ok ? Self.refreshInterval : Self.retryInterval))
			}
		}
	}

	/// Disabling drops the snapshot and deletes the cache — opting out leaves nothing behind.
	func setEnabled(_ enabled: Bool) {
		guard enabled != isEnabled else { return }
		isEnabled = enabled
		defaults.set(enabled, forKey: Self.consentKey)
		if enabled {
			start()
		} else {
			pump?.cancel()
			pump = nil
			rates = nil
			try? FileManager.default.removeItem(at: fileURL)
		}
	}

	func refreshNow() async -> Bool {
		guard isEnabled else { return false }
		return await fetchAndStore()
	}

	private func fetchAndStore() async -> Bool {
		// Guard 4 — at the network boundary itself; the pump may have been asleep when consent was
		// revoked, and this is the last line before a request goes out.
		guard isEnabled, let fetched = try? await Self.fetch() else { return false }
		// Re-checked after the await: consent can be withdrawn mid-flight, and a late response must
		// not resurrect the feature or write the cache back.
		guard isEnabled else { return false }
		rates = fetched
		if let data = try? JSONEncoder().encode(fetched) {
			try? data.write(to: fileURL, options: .atomic)
		}
		return true
	}

	/// Cacheless for the same reason as fiat: a shared session would leave a second copy on disk that
	/// revoking consent never deletes.
	private nonisolated static let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.urlCache = nil
		return URLSession(configuration: config)
	}()

	private nonisolated static func fetch() async throws -> CurrencyRates {
		let ids = CryptoData.all.map(\.id).joined(separator: ",")
		var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
		components.queryItems = [
			URLQueryItem(name: "ids", value: ids),
			URLQueryItem(name: "vs_currencies", value: base.lowercased()),
		]
		guard let url = components.url else { throw URLError(.badURL) }

		let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
		guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
			throw URLError(.badServerResponse)
		}

		// { "bitcoin": { "usd": 61033.46 }, … } — keyed by CoinGecko id, so map back to tickers.
		let prices = try JSONDecoder().decode([String: [String: Double]].self, from: data)
		let key = base.lowercased()
		var rates: [String: Double] = [:]
		rates.reserveCapacity(CryptoData.all.count + 1)
		for coin in CryptoData.all {
			// Inverted: the feed quotes USD per coin, while a rate table is units per 1 base.
			guard let price = prices[coin.id]?[key], price > 0, price.isFinite else { continue }
			let rate = 1 / price
			guard rate.isFinite, rate > 0 else { continue }
			rates[coin.code] = rate
		}
		guard !rates.isEmpty else { throw URLError(.cannotParseResponse) }
		rates[base] = 1

		return CurrencyRates(base: base, rates: rates, fetchedAt: Date())
	}
}

extension CurrencyRates {
	/// Fiat table with coin rates folded in. Both are quoted per 1 base, so this is a plain union —
	/// but only when the bases agree; a mismatch drops the coins rather than inventing a cross-rate.
	/// `fetchedAt` takes the newer of the two so `CalcMemo` re-evaluates when *either* feed lands.
	func merging(crypto: CurrencyRates?) -> CurrencyRates {
		guard let crypto, crypto.base == base else { return self }
		var merged = rates
		// Fiat wins any collision, matching the ident table's precedence.
		for (code, rate) in crypto.rates where merged[code] == nil { merged[code] = rate }
		return CurrencyRates(
			base: base, rates: merged, fetchedAt: max(fetchedAt, crypto.fetchedAt))
	}
}
