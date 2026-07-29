import SwiftUI

/// The catch-all pane. Home to currency conversion — the one feature in Tinycast that reaches the
/// network, which is why it ships off and needs an explicit yes before it can be switched on.
struct MiscellaneousSettingsView: View {
	@ObservedObject private var currencyRates = AppCore.shared.currencyRates
	@ObservedObject private var cryptoRates = AppCore.shared.cryptoRates
	@State private var askingConsent = false
	@State private var askingCryptoConsent = false
	@State private var refreshing = false
	@State private var refreshFailed = false

	var body: some View {
		SettingsPane(
			title: "Miscellaneous",
			subtitle: "Options that don't belong to a single feature."
		) {
			SettingsCard(header: "Calculator") {
				SettingsRow(
					title: "Currency Conversion",
					subtitle: conversionStatus,
					systemImage: "dollarsign.arrow.circlepath",
					tint: .green,
					statusDot: currencyRates.isEnabled ? .green : nil
				) {
					// Deliberately not bound straight to the setting: flipping it on only opens the
					// consent sheet, so the switch springs back until the user actually accepts.
					Toggle(
						"",
						isOn: Binding(
							get: { currencyRates.isEnabled },
							set: { wantsOn in
								if wantsOn {
									askingConsent = true
								} else {
									currencyRates.setEnabled(false)
								}
							})
					)
					.labelsHidden()
					.toggleStyle(.switch)
					.controlSize(.small)
				}

				SettingsDivider()
				SettingsRow(
					title: "Cryptocurrency",
					subtitle: cryptoStatus,
					systemImage: "bitcoinsign.circle",
					tint: .orange,
					statusDot: cryptoRates.isEnabled ? .green : nil
				) {
					Toggle(
						"",
						isOn: Binding(
							get: { cryptoRates.isEnabled },
							set: { wantsOn in
								if wantsOn {
									askingCryptoConsent = true
								} else {
									cryptoRates.setEnabled(false)
								}
							})
					)
					.labelsHidden()
					.toggleStyle(.switch)
					.controlSize(.small)
					// Coins are priced through the fiat base, so they can't answer anything alone.
					.disabled(!currencyRates.isEnabled)
				}

				if currencyRates.isEnabled {
					SettingsDivider()
					SettingsRow(
						title: "Exchange Rates",
						subtitle: ratesStatus,
						systemImage: "clock.arrow.circlepath",
						tint: .gray
					) {
						Button("Update Now") {
							refreshing = true
							Task {
								let landed = await currencyRates.refreshNow()
								refreshFailed = !landed
								refreshing = false
							}
						}
						.disabled(refreshing)
					}
				}
			}
		}
		.sheet(isPresented: $askingConsent) {
			CurrencyConsentSheet(
				onCancel: { askingConsent = false },
				onAccept: {
					askingConsent = false
					currencyRates.setEnabled(true)
				})
		}
		.sheet(isPresented: $askingCryptoConsent) {
			CryptoConsentSheet(
				onCancel: { askingCryptoConsent = false },
				onAccept: {
					askingCryptoConsent = false
					cryptoRates.setEnabled(true)
				})
		}
	}

	/// Says plainly why the row is unavailable rather than leaving a dead switch unexplained.
	private var cryptoStatus: String {
		guard currencyRates.isEnabled else {
			return "Turn on Currency Conversion first — coins are priced against it."
		}
		let examples = "Adds coins — \"1 btc in usd\", \"0.5 eth to eur\"."
		return cryptoRates.isEnabled
			? examples : "\(examples) Off — \(CryptoRateStore.provider) is not contacted."
	}

	/// Carries the off-state promise that used to need its own callout: nothing is contacted until
	/// the switch is on.
	private var conversionStatus: String {
		let examples = "Convert inline — \"100 dollars to yen\", \"€20 to GBP\"."
		return currencyRates.isEnabled ? examples : "\(examples) Off — no service is contacted."
	}

	private var ratesStatus: String {
		if refreshing { return "Updating…" }
		if refreshFailed { return "Couldn't reach \(CurrencyRateStore.provider). Try again." }
		guard let fetched = currencyRates.rates?.fetchedAt else {
			return "\(CurrencyRateStore.provider) · not downloaded yet."
		}
		let stamp = fetched.formatted(date: .abbreviated, time: .shortened)
		return "\(CurrencyRateStore.provider) · updated \(stamp). Refreshes daily."
	}
}

/// Crypto's own consent. A separate provider needs a separate yes: agreeing to Frankfurter is not
/// agreement to be talked about with CoinGecko.
private struct CryptoConsentSheet: View {
	let onCancel: () -> Void
	let onAccept: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
			HStack(spacing: Theme.Spacing.lg) {
				Image(systemName: "network")
					.font(.system(size: 22, weight: .medium))
					.foregroundStyle(.orange)
				Text("Turn on cryptocurrency prices?")
					.font(.headline)
			}

			Text(
				"Tinycast downloads coin prices from \(CryptoRateStore.provider) once an hour and "
				+ "keeps a copy on your Mac. This is a second provider, separate from exchange "
				+ "rates. No account, no identifiers, nothing you type. Turning it off deletes the "
				+ "cached prices."
			)
			.font(.callout)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)

			HStack(spacing: Theme.Spacing.lg) {
				Link(destination: CryptoRateStore.providerURL) {
					HStack(spacing: Theme.Spacing.xs) {
						Text(CryptoRateStore.providerURL.host() ?? "Provider")
						Image(systemName: "arrow.up.right.square")
					}
					.font(.callout)
				}
				Spacer()
				Button("Not Now", action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button("Enable", action: onAccept)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(Theme.Spacing.xxl)
		.frame(width: 420)
	}
}

/// The consent step. Three facts are the ones that actually decide the answer — who is contacted, how
/// often, and that nothing personal goes with it — plus the provider link so the claim is checkable.
private struct CurrencyConsentSheet: View {
	let onCancel: () -> Void
	let onAccept: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
			HStack(spacing: Theme.Spacing.lg) {
				Image(systemName: "network")
					.font(.system(size: 22, weight: .medium))
					.foregroundStyle(.green)
				Text("Turn on currency conversion?")
					.font(.headline)
			}

			Text(
				"Tinycast downloads exchange rates from \(CurrencyRateStore.provider) once a day and "
				+ "keeps a copy on your Mac. No account, no identifiers, nothing you type. "
				+ "Turning it off deletes the cached rates."
			)
			.font(.callout)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)

			HStack(spacing: Theme.Spacing.lg) {
				Link(destination: CurrencyRateStore.providerURL) {
					HStack(spacing: Theme.Spacing.xs) {
						Text(CurrencyRateStore.providerURL.host() ?? "Provider")
						Image(systemName: "arrow.up.right.square")
					}
					.font(.callout)
				}
				Spacer()
				Button("Not Now", action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button("Enable", action: onAccept)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(Theme.Spacing.xxl)
		.frame(width: 420)
	}
}
