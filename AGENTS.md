# roastier.af.codes

This orphan `gh-pages` branch *is* the published site; the app lives on `main`. GitHub Pages runs Jekyll on the branch root, which copies files without front matter verbatim, so add none. It drops names starting with `_` or `.`, and `_config.yml` keeps `og-image/`, `AGENTS.md` and `CLAUDE.md` off the site, so list any other unpublished root file in its `exclude`. Preview with `python3 -m http.server` from the root rather than opening the file.

Built per the global `static-site-rules` skill, as a sibling of the Alveary, Chromahora and Carouline sites (their `gh-pages` branches). Carry shared layout, components and scripts across rather than letting them drift.

## Look

- Colors come from the app on `main`: `--accent` is `AccentColor` (`#956b47`, the `AppIcon.icon` fill) in light and the dark icon's latte cup (`#d6b38b`) in dark; `--accent-text` in light is the coffee line in the icon's cup. Keep them in step with the app and the contrast ratios in the theme sheets' comments.
- The motif is steam rising up the hero's sides, drawn like the wisps over the icon's cup: an inline SVG in `index.html` and `og-image/og-image.html` (keep both copies equal), stroked in `--steam`.
- Feature sections pair a popover capture with its text, alternating sides; `#details` is plain columns between hairlines, and `#under-the-hood` mirrors the assertions table in `main`'s `README.md`.

## Theming

`styles/index-light.css` and `styles/index-dark.css` hold the tokens and the glow; `styles/index-common.css` holds everything else. Both theme sheets ship media-scoped, as do the `theme-color` metas and every `<picture>` dark `<source>`, so the page follows the OS without JavaScript. `scripts/dark-mode.js` only applies a stored toggle override, and repeats each sheet's `--bg`, so change them together.

## Images

### Screenshots

`images/popover-{idle,indefinite,timed}-{light,dark}.webp` are 652x558 captures (2x) of the menu bar popover, cut out along its alpha so they keep the arrow and corners. To regenerate:

1. `./scripts/build.sh --release` on `main`, copy the bundle elsewhere, set its `CFBundleIdentifier` to `com.afollestad.roastier.shots` and ad-hoc re-sign it, so its defaults and power assertions never touch an installed copy.
2. Seed the state through the relaunch-resume key, then launch within 60 seconds: `defaults write com.afollestad.roastier.shots relaunchSession -dict savedAt -date <now>` for indefinite, adding `deadline -date <now + 87m50s>` for timed (it reads 1 hr 30 min), and nothing for idle.
3. Put a plain backdrop window behind the popover (`#f5f5f5` light, `#1e1e1e` dark), switch the system appearance to match (an app-level `-AppleInterfaceStyle` doesn't reach the popover), and open it with System Events: `click UI element 1 of menu bar 1` of the process.
4. `screencapture -l<id>` renders Liquid Glass over nothing and comes out gray, so take the pixels from `screencapture -R<window bounds>` and the alpha from `screencapture -o -l<id>`, multiplied together in a short CoreGraphics script.
5. `cwebp -lossless -z 9 -alpha_q 100`. Every capture shares one size, repeated in `.popover-shot`'s `aspect-ratio` and each `<img>`'s `width`/`height`.

### Icons

- `images/app-icon-light.png` and `-dark.png` are `AppIcon.icon` renders at 256x256, converted to sRGB: `"/Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon --export-image --output-file out.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1` (`--rendition Dark` for dark), then `sips -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc"` and `sips -Z 256`.
- `favicon.png` is the light render at 96x96 in both themes; `apple-touch-icon.png` is it at 180x180 flattened onto the plate's `#966b47`.
- The header logo loads from `https://af.codes/images/af.png` on `--logo-circle`, whose values match af.codes and the other siblings; change them together.

### Link preview

`images/og-image.png` is rendered by `og-image/render.sh` from `og-image/og-image.html`, which links the site's own common and dark sheets. Re-render it in the same change as the name, tagline, dark colors, steam, icon or `popover-timed-dark.webp`, then check `file images/og-image.png` reports 1200 x 630 RGB and view it.
