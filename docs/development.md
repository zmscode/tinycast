# Development

How to build, test, package, and release Tinycast.

## Requirements

- macOS 26 or later (Liquid Glass).
- Xcode 26 installed — it provides the SwiftUI macro plugin and SDK used to build.

## First-time setup

Create the `Tinycast Self-Signed` code-signing identity once — builds sign with it, which keeps the
macOS Accessibility grant from being forgotten every rebuild. Follow **[signing.md](signing.md) §1**
(a few `openssl`/`security` commands).

## Build & run

Open the project in Xcode and run it:

```sh
open Tinycast.xcodeproj    # then press ⌘R
```

Or from the command line:

```sh
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug build
```

`xcodebuild` uses whatever `xcode-select` points at; if that's the Command Line Tools rather than
Xcode, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the SwiftUI
`@State`/`@FocusState` macros need Xcode's macOS platform).

`Tinycast.xcodeproj` is committed and generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — after changing project settings in `project.yml`,
run `xcodegen generate` and commit the result.

### The dev channel

Debug builds are a separate channel: **`Tinycast Dev.app`**, bundle id `com.tinycast.app.dev`. Since
every persisted thing is keyed by bundle
id — `~/Library/Preferences/<id>.plist` (settings + hotkey bindings),
`~/Library/Caches/<id>/` (clipboard history, calculator history, exchange rates, frequent emoji),
`~/Library/Application Support/<id>/` (the onboarding marker), the `SMAppService` login item, and the
Accessibility / Input Monitoring (TCC) grants — a build you run locally can't read or clobber the
installed app's state, and both can run side-by-side.

Consequences worth knowing:

- The dev build asks for Accessibility on its own the first time, and starts with **no** hotkeys bound
  and onboarding unseen. Grant + bind once; it persists across rebuilds (the fixed build path and the
  `Tinycast Self-Signed` identity keep the TCC grant alive).
- Don't bind the same global hotkey in both — whichever registered first wins.
- The Hyper Key's Caps Lock remap is `hidutil` state, which is **system-wide, not per-bundle**:
  quitting one build clears the remap for the other, which then needs a rebind (or relaunch) to
  restore it.

### Editor (VS Code) code-intelligence

Autocomplete / go-to-definition come from SourceKit-LSP driven by a `buildServer.json`. Generate it
once (it's machine-specific and git-ignored):

```sh
brew install xcode-build-server
xcode-build-server config -project Tinycast.xcodeproj -scheme Tinycast \
    --build_root "$PWD/build/DerivedData"
```

`--build_root` matches the fixed path the VS Code build task / F5 use, so the editor indexes what you
actually build. Do a build once (⌘⇧B or F5) to populate it. In VS Code, **F5** builds and launches the
app; changes always apply (fixed build path — no need to delete `build/`).

## Tests

There's no XCTest target. Four standalone harnesses, each compiling the **real** engine sources:

```sh
swiftc Tinycast/Core/FuzzyMatch.swift Tools/fuzz-test.swift \
    -o /tmp/fuzz-test && /tmp/fuzz-test                            # launcher fuzzy matcher

swiftc Tinycast/Core/Calculator/*.swift Tools/calc-test.swift \
    -o /tmp/calc-test && /tmp/calc-test                            # calculator engine

swiftc Tinycast/Core/FuzzyMatch.swift Tinycast/Core/Emoji/*.swift Tools/emoji-test.swift \
    -o /tmp/emoji-test && /tmp/emoji-test                          # emoji catalog + grid geometry

swiftc Tinycast/Core/FuzzyMatch.swift Tinycast/Core/FileBrowser.swift Tools/file-test.swift \
    -o /tmp/file-test && /tmp/file-test                            # file-grid path handling
```

Each harness links the shipping source rather than a copy, which is why
`Tinycast/Core/Calculator/`, `Tinycast/Core/Emoji/` and `Tinycast/Core/FuzzyMatch.swift` must all
stay Foundation-only. Don't paste an engine into `Tools/` to make a harness build — a copy silently
stops testing the real code. The emoji harness pulls in `FuzzyMatch` because `EmojiIndex` searches
with it.

`.github/workflows/ci.yml` runs the Debug build and all three harnesses on every push and pull
request, and is the source of truth for these commands.

## Generated data

Two Swift files are emitted by scripts and must never be hand-edited. Both download their source, so
run them online, then commit the result:

```sh
node Tools/gen-emoji.js            # -> Tinycast/Core/Emoji/EmojiData.generated.swift
node Tools/gen-currencies.js       # -> Tinycast/Core/Calculator/CurrencyData.generated.swift
```

`gen-currencies.js` joins two sources on the ISO code: **Frankfurter**'s currency list (the same feed
`CurrencyRateStore` fetches rates from, so the table and the rate source can't drift apart) and
**Unicode CLDR**'s `en` currency data, which supplies display names, signs and the singular/plural
noun. It reads the pinned `cldr-json` checkout rather than the host's `Intl`, whose output shifts
with the local ICU version and would make the file unreproducible.

Only unambiguous data is emitted. Anything two currencies claim — `dollars`, `pounds`, `krona` — is
left out and decided by hand in `CalcCurrency.contested`, the one currency table still written by
hand. Re-run the script when a currency is added or retired; nothing breaks in the meantime, since
an unquoted code just reports "no exchange rate".

## The fuzzy matcher

`Tinycast/Core/FuzzyMatch.swift` is a Swift port of fzf's `FuzzyMatchV2` (MIT — full notice in
[`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md)). It is an affine-gap alignment that finds the
*best* placement of the query rather than the first, with bonuses for word boundaries, camelCase
humps, path delimiters and consecutive runs.

Three properties that constrain callers:

- **Bonuses read the original case.** Lower-casing a candidate before scoring erases the camelCase
  signal (`rpv` → `RootPaletteView`). Only the equality test is case-folded, internally.
- **Score does not shrink with length.** fzf scores the matched region and ignores trailing text, so
  `Safari` and `Safari Technology Preview` tie. Every ranking site needs a shorter-name tiebreak.
- **`score` and `match` differ in cost.** `match` allocates a backtrace matrix to return positions
  (for highlighting); `score` skips it. Ranking sweeps thousands of candidates per keystroke — use
  `score` there.

`Tools/fuzz-test.swift` asserts *relative* orderings rather than absolute scores, so retuning a bonus
doesn't churn the suite. Every scoring rule has at least one case that fails if the rule is deleted —
verify with a mutation pass (zero out a bonus, confirm the suite goes red) before trusting a change.
Gap penalties and the first-char multiplier only scale scores rather than flip orderings, so those
are covered by margin assertions instead.

## Localization

`Tinycast/Localizable.xcstrings` is the String Catalog. `SWIFT_EMIT_LOC_STRINGS` extracts keys at
build time, and Xcode merges them into the catalog when you build in the IDE — open the catalog in
Xcode to add a language or fill in translations.

SwiftUI takes `LocalizedStringKey`, so `Text("Apps")` is localizable with no code change. A plain
`String` is not, so anything crossing a non-SwiftUI boundary needs `String(localized:)`:

```swift
Text("Apps")                                    // already localizable
alert.messageText = String(localized: "Quit?")  // AppKit — needs the wrapper
case .application: return String(localized: "Application")   // model property — needs it too
```

Don't wrap SF Symbol names, bundle ids or pasteboard types — they're API identifiers. Interpolated
keys (`"\(count) settings"`) become `%lld` entries in the catalog, where a translator can attach
plural rules.

`Core/Calculator/` and `Core/Emoji/` are deliberately unlocalized: they must stay Foundation-only
and pure so the harnesses can compile them.

## Packaging a DMG

For a local signed DMG:

```sh
./build-dmg.sh            # -> build/Tinycast-<version>.dmg (version from project.yml)
./build-dmg.sh 0.5.7      # -> build/Tinycast-0.5.7.dmg
```

It builds a Release `Tinycast.app` signed with `Tinycast Self-Signed` and packs it (with an
`/Applications` symlink). Official per-channel releases (beta/stable) are built by CI — see
below and [`.github/workflows/release.yml`](../.github/workflows/release.yml).

## Signing & Gatekeeper

Both local builds and CI releases sign with the same stable `Tinycast Self-Signed` identity (not an
Apple Developer ID), so macOS quarantines a directly-downloaded DMG — the Homebrew cask strips that
automatically, and direct downloaders run `xattr -dr com.apple.quarantine "…/Tinycast.app"` once.
Full details in [signing.md](signing.md).

## CI releases

`.github/workflows/release.yml` builds and publishes a DMG from GitHub Actions — no local machine
needed. Run it from the **Actions** tab (`Release` → **Run workflow**) and pick:

- **channel** — `beta` or `stable`. Each builds a distinct app
  (`Tinycast Beta.app` / `Tinycast.app`) with its own bundle id, alongside the local
  `Tinycast Dev.app` (above).
  Beta gets an auto-incrementing `-beta.N` suffix (`N` = the Actions run number)
  so re-running never collides; stable ships the version as-is.
- **version** — base semver, e.g. `0.2.0`.

It builds on a `macos-26` runner with Xcode 26 and publishes a GitHub Release tagged
`v<full-version>` with a versioned DMG asset (`Tinycast-<full-version>.dmg`), marked prerelease
for beta. On success it also bumps the matching cask in the tap (below).

### Homebrew tap automation

The release job's final step rewrites the `version` + `sha256` of the channel's cask (`tinycast`
or `tinycast@beta`) in the
[`homebrew-tinycast`](https://github.com/abue-ammar/homebrew-tinycast) tap and pushes. It needs a
`HOMEBREW_TAP_TOKEN` repo secret — a fine-grained PAT with **Contents: read/write** on the tap
repo. Without the secret the step logs a warning and skips (the release still publishes).
