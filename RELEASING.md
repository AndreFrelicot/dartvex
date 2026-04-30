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

- `dartvex-v0.1.0`
- `dartvex_flutter-v0.1.0`
- `dartvex_codegen-v0.1.0`
- `dartvex_local-v0.1.0`
- `dartvex_auth_better-v0.1.0`

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
- internal dependency constraint mismatches

To see the wider impact set:

```sh
dart scripts/release_packages.dart plan --include-dependents --since-ref=<git-ref>
```

## Prepare Packages

For each package you actually intend to publish:

1. update `version` in that package's `pubspec.yaml`
2. add a matching entry to that package's `CHANGELOG.md`
3. if an internal dependency now needs a newer version range, update the constraint in the dependent package and bump that dependent package too
4. run package tests and analysis
5. commit the release-prep changes before pub.dev dry-runs or publish

Typical order:

1. `dartvex`
2. `dartvex_codegen`
3. `dartvex_local`
4. `dartvex_auth_better`
5. `dartvex_flutter`

The helper will compute the exact order for the selected release set.

Before committing, verify package docs:

- each package README starts with the Dartvex logo from
  `https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png`
- each package README includes the "The Dartvex ecosystem" table linking the
  five public packages
- examples use current public APIs (`mutate`, `ConvexQuery`,
  `ConvexLocalClient.open`, and `dartvex_codegen generate --spec-file`)

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

When you are preparing on one machine and publishing on another:

1. commit the version, changelog, README, and example updates
2. push the release-prep commit
3. pull that exact commit on the publishing machine
4. verify no package directory contains a local `pubspec_overrides.yaml`
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
   `dart scripts/release_packages.dart dry-run --include-dependents`.
3. Publish in the computed order.
4. Create one tag per successfully published package on the published commit.
5. Push the tags.

If a publish fails midway, tag only the packages that were actually published,
fix the issue, then repeat planning from the remaining package tags.

## Practical Rule of Thumb

- If only one package changed and dependents still accept its version range, publish only that package.
- If a dependent package needs code changes or a tighter internal dependency range, bump and publish that dependent too.
- Do not republish untouched packages just because they live in the monorepo.
