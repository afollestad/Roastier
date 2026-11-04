## Bundle Resources

These instructions cover the app bundle inputs under `Resources/`.

- These are not SwiftPM resources; `scripts/build.sh` copies `Info.plist` and compiles the asset catalog and `AppIcon.icon` with `actool`.
- Keep `CFBundleExecutable` equal to the SwiftPM executable product name in `Package.swift`.
- Leave icon and accent color keys out of `Info.plist`; `scripts/build.sh` merges them from actool's output.
- Keep `Resources/Assets.xcassets/AccentColor.colorset` and `coffee` in `Sources/Roastier/PopoverView.swift` equal to the sRGB conversion of the `Resources/AppIcon.icon/icon.json` fill.
- Edit `AppIcon.icon` with Icon Composer.
- Keep `CoffeeMenuBarActive` and `CoffeeMenuBarIdleTemplate` on an 18 pt canvas with template rendering so macOS supplies their menu bar tint.
