# Addons

## `tycoon_core/`
The Tycoon Engine itself. This is the folder a game repo consumes as a git
submodule. See `../CLAUDE.md` (contract) and `../docs/build-plan.md` (rationale).

## `gut/` — GUT test harness (vendored)

GUT (Godot Unit Test, MIT licensed) is vendored directly here. GUT's upstream
repo is a full Godot project with the plugin nested at `addons/gut/`, so
submoduling the whole repo doesn't fit. The plugin source under this directory
was extracted from upstream `v9.6.0`.

To upgrade: download a release zip from
<https://github.com/bitwes/Gut/releases>, replace this directory with the
release's `addons/gut/` folder, and commit. Note the version in this README.

Enable it in **Project → Project Settings → Plugins** the first time you open
the project in the editor. CI runs `gut_cmdln.gd` directly without enabling the
plugin — see `.github/workflows/test.yml`.
