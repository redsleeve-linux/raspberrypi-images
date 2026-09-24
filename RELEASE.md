# Cutting a release

Maintainer notes. The README is for people downloading and booting the image; this file is for
publishing one. See `NOTES.md` for the build's history and open problems.

## Tag scheme

```
<point release>-<build date>
```

`9.8-20260923`, and `10.0-20270415` once RedSleeve 10 exists. The point release names the package
set the image was built from, the date distinguishes rebuilds within it. Several images per point
release are normal and expected - cut one whenever there is a reason to (a new point release,
errata worth baking in, a kickstart change).

No `v` prefix: the version is RedSleeve's, not this repository's.

Two things worth knowing about the scheme:

- `10.0-20270415` sorts _before_ `9.8-20260923` lexically. GitHub lists releases newest-first by
  date, so the releases page is unaffected; locally use `git tag --sort=v:refname`.
- The workflow's tag filter is `[0-9]*`, so it already matches future major versions. Nothing to
  change there when 10 arrives.

## Which package set an image contains

The kickstart installs from the official mirrorlists, which point at the **rolling** `el9/9/` tree:

```
http://ftp.redsleeve.org/pub/el9/mirrors_baseos  ->  .../pub/el9/9/BaseOS
```

That tree is the _current_ point release and receives errata in place - as of 2026-09-23, `9/` and
`9.8/` are byte-identical (same `repomd.xml` revision, same mtime), while `9.7/` froze in May 2026
when 9.8 superseded it.

So there is no separate "9.8 GA snapshot" to build against. Building from `9/` gives an image that
already carries every erratum released to date, which is what you want on a Pi: a fresh `dnf update`
right after first boot is close to a no-op instead of a long transaction on a slow SD card, and the
image does not ship with months-old known-vulnerable packages.

Pinning the build to `9.8/` would produce an identical image today, and a progressively staler one
after 9.9 ships. The tag records which point release an image came from; the repositories on the
booted system keep tracking `9/`, so `dnf update` carries a user forward across point releases the
normal EL way.

**The guard.** Because the mirrorlists move, a tag cut around a point-release bump can claim the
wrong version. The workflow compares the tag's prefix against the `redsleeve-release` version it
finds in BaseOS and fails in the first minute if they disagree:

```
tag 9.8-20260923 claims RedSleeve 9.8, but the repositories are at 9.9. Re-tag as 9.9-20260923.
```

Do what it says - delete the tag and re-cut it (below). Better a failure at minute one than a
mislabelled release after four hours.

## Before tagging

Per the repo convention, a release is only worth cutting from a commit you have actually booted:

```sh
./build                                             # or tools/wsl-build.sh from a Windows checkout
sudo tools/verify-image.sh rpi-image/<image>.raw    # loop-mount checklist
tools/rapid-boot-test.sh <pi-ip> 15                 # needs a Pi and sshpass
```

Commit everything first - the workflow builds the tagged commit, not your working tree.

## Cutting it

```sh
git tag 9.8-20260923
git push origin 9.8-20260923
```

That is the whole procedure. The workflow then:

1. builds the image on an `ubuntu-24.04` runner (measured 8m26s end to end on 2026-09-23, so the
   240-minute timeout is generous; GitHub's hard cap is 6 hours),
2. runs `tools/verify-image.sh` over the raw image,
3. compresses it and writes a `.sha256`,
4. uploads the image and logs as workflow artifacts,
5. creates the release and attaches `…raw.xz`, `…raw.xz.sha256` and `…log.tar.xz`.

The release is created **only after the build succeeds**, so it never sits empty for hours while the
build runs. The image is named after the tag, so the asset name and the tag cannot disagree.

## If the build fails

No release was created, so there is nothing to clean up on the releases page. Delete the tag, fix
the problem, re-tag:

```sh
git push --delete origin 9.8-20260923
git tag -d 9.8-20260923
```

Re-running a tag build that already produced a release does not recreate it: the workflow creates
the release once and afterwards only replaces the assets (`gh release upload --clobber`), so notes
you have edited by hand survive a re-run.

## Test builds without a release

Use **Run workflow** on the Actions tab (`workflow_dispatch`). It builds and uploads artifacts but
never touches releases; the `store_as_artifact` input turns the image artifact off if you only want
the logs. Artifacts expire (90 days by default), release assets do not.

## Cost

The repository is public, so this is free: unlimited standard-runner minutes, free artifact storage,
and free release downloads with no bandwidth cap. Public repos also get the 4-core/16 GB runner
rather than the 2-core/8 GB private one, which matters for a qemu-emulated build.

Two limits worth remembering: release assets are capped at **2 GiB per file** (the image is ~185 MB
compressed, so there is plenty of room), and a runner only guarantees 14 GB of disk - the workflow
deletes the preinstalled toolchains and drops the 3.5 GB raw image as soon as it is compressed to
stay inside that.

If the repository is ever made private, this changes sharply: 2,000 minutes/month and 500 MB of
artifact storage on the Free plan, and one build can consume a large share of both.

## When RedSleeve 10 arrives

The tag filter and the release machinery need no changes. What does:

- a new kickstart under `kickstart/`, and the `kickstart=` value in the workflow's _Set environment
  variables_ step;
- the `repoquery` URL in that same step, which is hardcoded to
  `…/pub/el9/9/BaseOS` for the release-number lookup;
- the mirrorlist URLs in the kickstart (`pub/el9/mirrors_*`);
- `release_str`'s fallback of `9` in the workflow.

Whether 10 images live in this repository alongside 9, or the tags grow a distro prefix
(`redsleeve-10.0-…`) because something other than RedSleeve shows up here, is a decision for then -
the `[0-9]*` filter assumes the former.
