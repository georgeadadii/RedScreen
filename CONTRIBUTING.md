# Contributing to RedScreen

`main` is the only integration branch. Start each issue from an updated `origin/main`, open its
pull request against `main`, and delete the issue branch after merging. Never reuse a merged
feature branch as the base for another issue. Existing Linear handoffs naming
`feature/issue-1-bootstrap` describe the retired workflow; use `main` instead.

## Start an issue

```sh
git switch main
git pull --ff-only origin main
git switch -c feature/red-123-short-description
```

Use a prefix that matches the work: `feature/` for new functionality, `fix/` for bug fixes,
or `docs/` or `chore/` for documentation or maintenance. Use the issue identifier and a
concise description. Keep each branch focused on one issue.
When one issue depends on another, merge the dependency into `main` before starting the next
branch. A deliberately stacked workflow requires an explicit plan; the default CI policy rejects
PRs whose base is not `main`.

## Validate and submit

```sh
make build
make test-core
make test
```

`make test-core` runs the core tests without UI automation. `make test` also runs the UI tests;
run it in a logged-in macOS desktop session, especially for application/UI changes. GitHub CI
requires the application build and core tests. Generated fixtures are committed synthetic data;
regenerate them only when intentionally changing the corpus.

Push your branch and create a PR with base `main`. Include the issue reference, what changed, and
the validation results. Check the base shown in GitHub before submitting. Wait for **Build and
core tests** to pass and resolve review conversations before merging. Required checks also apply
to administrators. A second-person approval is not required for this single-maintainer project.

Use a normal merge commit when joining histories or maintaining an explicitly stacked branch
chain. Squash merging is fine for an ordinary completed issue branch that will be deleted and
never reused. Do not force-push or delete `main`.

## After merging

GitHub automatically deletes merged PR branches. Refresh your local checkout:

```sh
git switch main
git pull --ff-only origin main
git fetch origin --prune
git branch -d feature/red-123-short-description
```

After a squash merge, Git may refuse `branch -d` because commit ancestry differs. First confirm
the PR is merged and all intended changes are present in `main`; then `git branch -D` may remove
that specific local branch. Do not bulk-delete branches based only on their age.

New clones should resolve their remote default branch to `main`. For an older clone whose
`origin/HEAD` still points at bootstrap, run `git remote set-head origin -a`.
