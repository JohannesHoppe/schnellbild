# The app's releases that have no Schnellbild.dmg yet, newest first, from one
# page of GitHub's release list (GET /repos/{owner}/{repo}/releases lists the
# newest first). Each one counts, however many data and VLCKit pre-releases
# came after it: the app's releases are tagged v<version> and are never
# pre-releases. mac-release.yml reads every page:
#   gh api --paginate "repos/$R/releases?per_page=100" --jq "$(cat Scripts/unfinished_releases.jq)"
.[]
| select((.draft | not) and (.prerelease | not) and (.tag_name | test("^v[0-9]")))
| select(any(.assets[]?; .name == "Schnellbild.dmg") | not)
| .tag_name
