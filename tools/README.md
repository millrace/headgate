# tools/

Scripts that collapse the repetitive commit/release steps into a single
approvable command — review them once, approve `tools/<name>.sh`, and the
individual `git`/`gh` steps stop prompting.

| script | what |
|---|---|
| `commit.sh "<msg>"` | `git add -A` + commit with the `Co-Authored-By` trailer, no GPG prompt |
| `release.sh <X.Y.Z> [msg]` | push main, tag `vX.Y.Z`, push the tag, wait for the **headgate zip** CI |

Typical flow:

```sh
tools/commit.sh "headgate: …"
tools/release.sh 0.0.5 "v0.0.5 — …"
```
