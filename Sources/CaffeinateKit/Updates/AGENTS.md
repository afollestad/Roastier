## App Updates

These instructions cover the update checker, downloader, stager, and installer under `Sources/CaffeinateKit/Updates/`.

- Keep the release artifact contract aligned with `scripts/ci/create-release-zip.sh` and `scripts/ci/create-github-release.sh`: stable `vX.Y.Z` releases attach a notarized `Caffeinate.app.zip` containing `Caffeinate.app` at the top level.
- Check and download anonymously over `URLSession`; the repository is public, so never add a `gh` or token dependency end users lack.
- Installable updates require GitHub's SHA-256 asset digest, verified against the downloaded ZIP before staging; it is the supply-chain integrity gate.
- **Keep update ZIP downloads non-cached in all four places**: the `.ephemeral` session, the request `cachePolicy`, the `no-cache`/`Pragma` headers, and those headers re-applied on redirect. A cached response stages a stale asset.
- Automatic checks never re-download a tag whose download already failed; manual checks always retry.
