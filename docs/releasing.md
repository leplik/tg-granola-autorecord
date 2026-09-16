# Releasing

Releases are built on the maintainer's Mac. The Developer ID private key never leaves that Mac, and no signing secrets live in GitHub.

## One-time setup

1. **Developer ID certificate.** Check that the keychain has a "Developer ID Application" identity:

   ```sh
   security find-identity -v -p codesigning
   ```

2. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com) under **Sign-In and Security → App-Specific Passwords**, then store it in the keychain:

   ```sh
   xcrun notarytool store-credentials tg-granola-autorecord \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID"
   ```

   `notarytool` prompts for the password. An App Store Connect API key works too:

   ```sh
   xcrun notarytool store-credentials tg-granola-autorecord \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer 00000000-0000-0000-0000-000000000000
   ```

3. **GitHub CLI.** `gh auth status` must show a signed-in account with push access to this repository and to `leplik/homebrew-tap`.

## Cutting a release

1. Bump `Product.version` in `Sources/AutorecordCore/Product.swift`.
2. Move the `Unreleased` notes in `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD` heading and update the links at the bottom.
3. Commit and push to `main`, and wait for CI to pass.
4. Run:

   ```sh
   make release
   ```

The script checks the tree, keychain, notarization profile and changelog first. Then it runs the tests, builds a universal app signed with the hardened runtime, notarizes and staples it, and zips it with a checksum. Finally it tags the commit, creates the GitHub release with notes from the changelog, and updates `Casks/tg-granola-autorecord.rb` in the tap.

To check signing and notarization without publishing anything:

```sh
DRY_RUN=1 scripts/release.sh
```
