<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="96" height="96">
  </picture>
</p>

<h1 align="center">Roastier</h1>

<p align="center">A macOS menu bar app that keeps your Mac awake.</p>

<p align="center">
  <a href="https://github.com/afollestad/Roastier/releases/latest/download/Roastier.app.zip">
    <img src=".github/download-macos.svg?v=240x42" alt="Download Roastier for macOS (latest release)" width="240" height="42">
  </a>
</p>

Click the coffee cup for a **Stay awake** toggle and a duration slider, from **Indefinite** up to 12 hours, which counts down during a timed session. The cup is filled while your Mac is kept awake.

While on, it holds the same IOKit power assertions as `caffeinate -dims`:

| Flag | Assertion |
| --- | --- |
| `-d` | `PreventUserIdleDisplaySleep` |
| `-i` | `PreventUserIdleSystemSleep` |
| `-m` | `PreventDiskIdle` |
| `-s` | `PreventSystemSleep` (AC power only) |

## Install

Roastier needs macOS 26 or later. Download `Roastier.app.zip` from the [latest release](https://github.com/afollestad/Roastier/releases/latest), unzip it, and move `Roastier.app` to `/Applications` before turning on **Launch at login**, so the login item points there.

It keeps itself up to date, checking at launch and every 6 hours. A dot on the menu bar icon marks an update and turns green once it's downloaded; **Restart to Update** in the popover installs it, and an active **Stay awake** session resumes afterward. Updates replace the app in place, so keep it somewhere writable.

## Development

Building needs Xcode 26 or later, and Homebrew for SwiftLint and xcsift.

```sh
./scripts/setup.sh    # install tools and the pre-commit hook
./scripts/build.sh    # build .build/app/debug/Roastier.app (--release for an optimized build)
./scripts/run.sh      # build, then (re)launch the app
./scripts/test.sh     # run unit tests (optionally pass a filter)
./scripts/lint.sh     # run SwiftLint (--fix to autocorrect)
```

Launch through `run.sh` rather than `swift run` or Xcode, since only the bundle `build.sh` assembles has the app's assets. [RELEASING.md](RELEASING.md) covers how releases are built and published.
