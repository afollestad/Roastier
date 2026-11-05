<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="128" height="128">
  </picture>
</p>

<h1 align="center">Roastier</h1>

<p align="center">A macOS menu bar app that keeps your Mac awake.</p>

<p align="center">
  <a href="https://github.com/afollestad/Roastier/releases/latest/download/Roastier.app.zip">
    <img src=".github/download-macos.svg?v=240x42" alt="Download Roastier for macOS (latest release)" width="240" height="42">
  </a>
</p>

Roastier is equivalent to `caffeinate -dims`. Click the coffee cup to open a Liquid Glass popover with a **Stay awake** toggle and a duration slider: **Indefinite** at the far left, then 5-minute steps up to an hour, widening to hourly steps toward 12 hours. During a timed session the slider counts down, returning to **Indefinite** when time is up. The cup is filled while your Mac is being kept awake and outlined while idle; macOS supplies its tint to suit the menu bar.

While on, it holds the same IOKit power assertions as `caffeinate -dims`:

| Flag | Assertion |
| --- | --- |
| `-d` | `PreventUserIdleDisplaySleep` |
| `-i` | `PreventUserIdleSystemSleep` |
| `-m` | `PreventDiskIdle` |
| `-s` | `PreventSystemSleep` (AC power only) |

## Requirements

- macOS 26 or later
- Xcode 26 or later
- Homebrew (for SwiftLint and xcsift)

## Development

```sh
./scripts/setup.sh    # install tools and the pre-commit hook
./scripts/build.sh    # build .build/app/debug/Roastier.app (--release for an optimized build)
./scripts/run.sh      # build, then (re)launch the app
./scripts/test.sh     # run unit tests (optionally pass a filter)
./scripts/lint.sh     # run SwiftLint (--fix to autocorrect)
```

This is a SwiftPM package; `scripts/build.sh` assembles the `.app` bundle and compiles its assets with `actool`.

## Install

Download `Roastier.app.zip` from the latest [GitHub Release](https://github.com/afollestad/Roastier/releases/latest), unzip it, and move `Roastier.app` to `/Applications`. To build it yourself:

```sh
./scripts/build.sh --release
cp -R .build/app/release/Roastier.app /Applications/
```

Turn on **Launch at login** from the installed copy so the login item points at `/Applications`.

Roastier keeps itself up to date. It checks GitHub Releases at launch and every 6 hours, and downloads a new version in the background. A dot on the menu bar icon marks an available update and turns green once it's downloaded; click **Restart to Update** in the popover to install it, and an active **Stay awake** session resumes after the restart. Updates replace the app in place, so keep it somewhere writable, such as `/Applications`.

See `RELEASING.md` for how releases are built and published.
