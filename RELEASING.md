# Releasing Dartvex Packages

This repo publishes to pub.dev per package, not as a lockstep monorepo release.

That means:

- bump and publish the packages that actually changed
- only republish dependent packages when their own code changed or their internal version constraints must move
- publish internal dependencies first, then dependents

Prepare release bumps in git before moving to the publishing machine. The
machine that runs `dart pub publish` or `flutter pub publish` should publish
from an already committed release-prep commit, not from local-only version
edits. Create package tags only after each package is successfully published.

## Release Tags

The release helper uses one git tag per package:

- `dartvex-v0.3.0`
- `dartvex_flutter-v0.3.0`
- `dartvex_codegen-v0.3.0`
- `dartvex_local-v0.3.0`
- `dartvex_auth_better-v0.3.0`
- `dartvex_auth_convex-v0.1.0` (once published)

If older releases were published before tags existed, use `--since-ref=<git-ref>`
for that release, then start tagging packages after the next publication.

## Plan a Release

From the repo root:

```sh
dart scripts/release_packages.dart plan --since-ref=<git-ref>
```

Once package tags exist:

```sh
dart scripts/release_packages.dart plan
```

To include packages with README/pubspec metadata changes after their package
tags, use the default tag-based plan. Do not rely only on calendar windows such
as "changes since April"; each package's latest `package-vX.Y.Z` tag is the
publish baseline.

What the plan shows:

- packages changed since the package baseline
- internal dependents impacted by those changes
- publish order for the selected set
- internal dependency constraint mismatches (a mismatch in `dev_dependencies`,
  such as `dartvex_codegen`'s dev dependency on `dartvex`, is only a warning:
  dev dependencies are not publish-order edges and do not reach pub.dev
  users)

To see the wider impact set:

```sh
dart scripts/release_packages.dart plan --include-dependents --since-ref=<git-ref>
```

## Track the Official Convex Client

`dartvex` mirrors a specific release of the official Convex JavaScript client
(`convex` on npm). That release is `convexSyncApiVersion` in
`packages/dartvex/lib/src/config.dart`; it is also the default
`ConvexClientConfig.apiVersion` sent in the `/api/<version>/sync` path, and
docs that say "matches the official client" refer to it. Bump it only on
purpose, in a `dartvex` release:

1. Pick the target `convex` release (usually the latest:
   `npm view convex version`).
2. Diff the official client between the pinned and the target version and
   port every behavior change, or record why it does not apply. At minimum
   review:
   - `src/browser/sync/protocol.ts` (messages and fields)
   - `src/browser/sync/web_socket_manager.ts` (reconnect, backoff, close codes)
   - `src/browser/sync/client.ts` (request, query, and transition handling)
   - `src/browser/sync/authentication_manager.ts` (token fetch and refresh)
   - `src/values/` (value encoding, including new special types)

   `scripts/protocol-watch.sh` downloads both versions from the npm registry
   and writes these diffs to `source-diff.patch` (the weekly Protocol Watch
   workflow attaches it to the `protocol-drift` issue):

   ```sh
   ./scripts/protocol-watch.sh   # exit 1 = drift, see drift-report.md
   ```

3. Update `convexSyncApiVersion`, the "Compatibility" notes in the root and
   `dartvex` READMEs, and the `dartvex` CHANGELOG ("Parity baseline is now
   ...").

## Prepare Packages

For each package you actually intend to publish:

1. update `version` in that package's `pubspec.yaml`
2. when bumping `dartvex`, update `dartvexVersion` in
   `packages/dartvex/lib/src/config.dart` to the same version (it is the
   default `clientId`, `dartvex-<version>`; `config_test.dart` fails if it
   differs from the pubspec)
3. move the `## [Unreleased]` entries of that package's `CHANGELOG.md` under
   a `## [X.Y.Z] - YYYY-MM-DD` heading (keep an empty `## [Unreleased]` above
   it), and mark every breaking change with **Breaking:**
4. if an internal dependency now needs a newer version range, update the constraint in the dependent package and bump that dependent package too
5. run package tests and analysis
6. sweep `skills/`, the package READMEs, the root README, and the examples
   for API drift: snippets, class/enum/method names, behavior claims, and
   version ranges must match the versions being published (skills describe
   the published API, not unreleased `main`)
7. commit the release-prep changes before pub.dev dry-runs or publish

CI also checks each package against its declared SDK floor (the `min-sdk` and
`min-sdk-flutter` jobs: `pub downgrade` + analyze, then tests). When you raise
a dependency's lower bound or a package's `environment` constraint, update
the floor in that job's matrix.

Typical order:

1. `dartvex`
2. `dartvex_codegen`
3. `dartvex_local`
4. `dartvex_auth_better`
5. `dartvex_auth_convex`
6. `dartvex_flutter`

The helper will compute the exact order for the selected release set.

Before committing, verify package docs:

- each package README starts with the Dartvex logo from
  `https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png`
- each package README includes the "The Dartvex ecosystem" table linking the
  five public packages
- examples use current public APIs (`mutate`, `ConvexQuery`,
  `ConvexLocalClient.open`, and `dartvex_codegen generate --spec-file`)

## Run the Live Convex Gate

The hermetic unit tests are not enough for a publication. Before publishing,
run the live gate against a real Convex deployment of `example/convex-backend`:

```sh
export CONVEX_DEPLOYMENT_URL=https://your-deployment.convex.cloud
export CONVEX_TEST_QUERY=messages:listPublic
export CONVEX_TEST_MUTATION=messages:sendPublic
export CONVEX_TEST_AUTH_TOKEN="$(cd example/convex-backend && npm run -s token)"

scripts/release_live_gate.sh
```

This script fails when the environment is missing instead of letting the live
tests self-skip. It runs the `dartvex` live integration/conformance suite and
the `dartvex_local` replay integration test.

## Run pub.dev Dry-Runs

Dry-run only the directly changed packages:

```sh
dart scripts/release_packages.dart dry-run --since-ref=<git-ref>
```

Dry-run changed packages plus impacted dependents:

```sh
dart scripts/release_packages.dart dry-run --include-dependents --since-ref=<git-ref>
```

Dry-run every package in the repo:

```sh
dart scripts/release_packages.dart dry-run --all
```

The helper automatically uses `dart` or `flutter` based on the package type.
It also expects a clean git state for the selected packages, because pub.dev
warns on modified tracked files.

By default the helper writes temporary `pubspec_overrides.yaml` files in its
publish copies, including copied examples, so unreleased internal packages can
be validated together. After publishing an internal dependency, rerun affected
dependents without these overrides to verify the same package resolution that
pub.dev users will get:

```sh
dart scripts/release_packages.dart dry-run --include-dependents --no-internal-overrides
```

For releases where `dartvex` itself changes, this is a two-phase gate:

1. before publishing `dartvex`, run the dry-run with internal overrides so the
   unpublished package set can be checked together
2. publish `dartvex`
3. wait for pub.dev to resolve the new `dartvex` version
4. rerun the dependent package dry-runs with `--no-internal-overrides`

Do not publish dependent packages until the no-overrides dry-run is green.

When you are preparing on one machine and publishing on another:

1. commit the version, changelog, README, and example updates
2. push the release-prep commit
3. pull that exact commit on the publishing machine
4. verify no package directory contains a local `pubspec_overrides.yaml`
   (`scripts/ci-local-dependency-overrides.sh` writes them for local
   development)
5. run the dry-runs there before publishing

## Publish

Publish from each package directory, in the computed order:

```sh
cd packages/dartvex
dart pub publish
```

```sh
cd packages/dartvex_flutter
flutter pub publish
```

After each successful publication, create the corresponding tag:

```sh
git tag dartvex-v0.1.1
git tag dartvex_flutter-v0.1.1
```

Then push commits and tags:

```sh
git push origin main --tags
```

Recommended cross-machine flow:

1. On the prep machine, commit release-prep changes and push the branch.
2. On the publishing machine, pull the release-prep commit and run
   `dart scripts/release_packages.dart dry-run --include-dependents` (with
   internal overrides, so the unpublished set is checked together).
3. Publish the internal dependencies first (`dartvex` when it changed).
4. Wait until pub.dev serves the new versions, then rerun the dependents'
   dry-run with `--no-internal-overrides`.
5. Publish the dependents in the computed order once that dry-run is green.
6. Create one tag per successfully published package on the published commit.
7. Push the tags.

If a publish fails midway, tag only the packages that were actually published,
fix the issue, then repeat planning from the remaining package tags.

## Practical Rule of Thumb

- If only one package changed and dependents still accept its version range, publish only that package.
- If a dependent package needs code changes or a tighter internal dependency range, bump and publish that dependent too.
- Do not republish untouched packages just because they live in the monorepo.
