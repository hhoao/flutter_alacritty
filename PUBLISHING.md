# Publishing to pub.dev

The FFI plugin is a **separate repo**
([rust_lib_flutter_alacritty](https://github.com/hhoao/rust_lib_flutter_alacritty)),
linked here as `packages/rust_lib_flutter_alacritty/` (git submodule).

The PTY backend is
[`flutter_pty_new`](https://pub.dev/packages/flutter_pty_new)
([hhoao/flutter_pty_new](https://github.com/hhoao/flutter_pty_new)).

All three packages are on pub.dev. **Preferred path:** GitHub Actions + pub.dev
OIDC (no long-lived tokens in the repo).

## One-time OIDC setup (each package)

Do this once per package on [pub.dev](https://pub.dev):

1. Sign in as a package uploader → **Admin** tab.
2. **Automated publishing** → enable **Publishing from GitHub Actions**.
3. Repository:
   - `rust_lib_flutter_alacritty` → `hhoao/rust_lib_flutter_alacritty`
   - `flutter_pty_new` → `hhoao/flutter_pty_new`
   - `flutter_alacritty` → `hhoao/flutter_alacritty`
4. Tag pattern: `v{{version}}` (tag `v2.2.0` publishes version `2.2.0`).
5. *(Optional)* Require GitHub environment `pub.dev` with reviewers on both
   pub.dev and the publish job in `.github/workflows/publish.yml`.

Workflows:

| Repo | Trigger | Workflow |
|------|---------|----------|
| `rust_lib_flutter_alacritty` | push tag `v*` | `.github/workflows/publish.yml` |
| `flutter_pty_new` | push tag `v*` | `.github/workflows/publish.yml` |
| `flutter_alacritty` | push tag `v*` | `.github/workflows/publish.yml` |

`auto-tag.yml` in each repo creates `v{version}` when `pubspec.yaml` version
changes on `main`. Tag push also runs `release.yml` (desktop binaries) in
`flutter_alacritty`.

## Release order

1. **rust_lib_flutter_alacritty** — bump `pubspec.yaml` + `CHANGELOG.md`, push
   `main` (auto-tag) or push `v0.x.y` manually. Wait until
   [pub.dev](https://pub.dev/packages/rust_lib_flutter_alacritty) shows the new
   version.
2. **flutter_pty_new** — bump `pubspec.yaml` + `CHANGELOG.md` in
   [hhoao/flutter_pty_new](https://github.com/hhoao/flutter_pty_new), push
   `main` (auto-tag) or push `v1.x.y` manually. Wait until
   [pub.dev](https://pub.dev/packages/flutter_pty_new) shows the new version.
   Configure OIDC on pub.dev for repository `hhoao/flutter_pty_new`.
3. **flutter_alacritty** — bump `rust_lib_flutter_alacritty` and
   `flutter_pty_new` constraints, `pubspec.yaml` version, and `CHANGELOG.md`;
   push `main` or tag `v*`. The publish workflow checks that the required
   `rust_lib` and `flutter_pty_new` versions exist on pub.dev before publishing.

Local `dependency_overrides` (path submodule / local PTY worktree) stay in the
dev tree; CI strips them before `dart pub publish`.

Use `PUB_HOSTED_URL=https://pub.dev` if your shell points at a mirror.

## Publish an already-tagged version (e.g. v2.2.0)

OIDC only runs on **tag push**. If the tag existed before `publish.yml` was on
`main`, re-push the tag after merging the workflow:

```bash
# rust_lib (from rust_lib_flutter_alacritty repo)
git tag -d v0.2.0
git push origin :refs/tags/v0.2.0
git tag -a v0.2.0 -m "Release v0.2.0" <commit>
git push origin v0.2.0

# flutter_pty_new (from flutter_pty_new repo)
git tag -d v1.0.0
git push origin :refs/tags/v1.0.0
git tag -a v1.0.0 -m "Release v1.0.0" <commit>
git push origin v1.0.0

# flutter_alacritty (after rust_lib and flutter_pty_new are on pub.dev)
git tag -d v2.2.0
git push origin :refs/tags/v2.2.0
git tag -a v2.2.0 -m "Release v2.2.0" c884a43
git push origin v2.2.0
```

## Manual fallback

```bash
dart pub login   # once per machine
cd packages/rust_lib_flutter_alacritty
dart pub publish --dry-run && dart pub publish

# flutter_pty_new (from its own repo)
dart pub publish --dry-run && dart pub publish

cd /path/to/flutter_alacritty
# Remove dependency_overrides from pubspec.yaml first
dart pub get && dart pub publish --dry-run && dart pub publish
```

## Pre-flight checklist

- [ ] OIDC configured on pub.dev for all three packages (or `dart pub login` for manual)
- [ ] `flutter test` and `flutter analyze lib test` pass
- [ ] Versions + `CHANGELOG.md` updated in all repos
- [ ] `rust_lib_flutter_alacritty` published before `flutter_alacritty`
- [ ] `flutter_pty_new` published before `flutter_alacritty`
- [ ] **Precompiled binaries:** push Rust changes to `rust_lib_flutter_alacritty`
      `main` and wait for
      [precompile-binaries](https://github.com/hhoao/rust_lib_flutter_alacritty/actions)
      CI before publishing (consumers without Rust need the matching GitHub
      release). See `packages/rust_lib_flutter_alacritty/docs/PRECOMPILED_BINARIES.md`.
