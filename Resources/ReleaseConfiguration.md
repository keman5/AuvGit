# Release signing and update feed

Run `scripts/notarize-app.sh` on the local Mac after setting `RAYGIT_SIGN_IDENTITY` to an installed Developer ID Application identity and `RAYGIT_NOTARY_PROFILE` to a keychain profile created with `xcrun notarytool store-credentials`. The script builds locally, signs with hardened runtime and timestamp, submits to Apple, staples the accepted ticket, assesses Gatekeeper, and produces `.artifacts/RayGit-release.zip`. No signing identity or notarization credentials are included in the repository. These steps require the user's Apple developer account; creating this script does not establish that a release has been notarized.

In RayGit Settings → Extensions, configure a trusted HTTPS manifest URL. An update check reads this JSON and displays its release link; it never replaces the installed application automatically:

```json
{
  "version": "0.2.0",
  "downloadURL": "https://your-release-host.example/RayGit-release.zip",
  "notes": "Release notes"
}
```

The manifest and download link must use HTTPS. The caller controls which host is trusted. Network errors, invalid responses, oversized manifests, malformed JSON, and invalid download URLs appear in settings.

Git Flow controls use the current repository. Start requires a clean index/worktree and existing configured main/develop branches. Finish checks the current Flow branch, merges locally, adds release/hotfix tags, then uses Git's safe `branch -d`. A merge conflict stops immediately and preserves Git's conflict state for normal resolution; no automatic reset or force deletion occurs. Pull/merge request controls open the provider's comparison/request preparation page in the system browser; creating and sending a request remains a browser action.
