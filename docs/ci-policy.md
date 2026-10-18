# CI execution policy

CI runs on pull requests, main pushes and manual dispatch. Other branch pushes
are covered when a PR is opened, avoiding duplicate push/PR builds. There are no
workflow path filters: the existing `cabal test` check always reports a result.
It succeeds only after successful classification and either successful execution
of all four small fixture test suites or an explicitly classified documentation-only PR.

| Change/event | All four fixture test suites |
| --- | --- |
| PR: root Markdown or docs Markdown only, including deletion | Skip |
| PR: Haskell, Cabal, scripts, workflow, unknown, mixed or renamed code | Run |
| main push or manual dispatch | Run |
| Missing baseline, new history or non-ancestor | Run |

Main always tests the whole tree: cancelling an earlier run must not allow a
later docs commit to count as evidence for untested code. Concurrency cancels old
runs of this workflow for the same PR/ref. Cabal's store and build cache are
scoped to OS, exact GHC/Cabal versions and all project/manifests; an SHA suffix
allows a successful build to refresh an immutable cache. Cabal still updates the
index and runs all four test suites on every selected run. Compilation needed by
those unit tests remains; this is not a compiler-free gate.

The owner's 2026-10-18 policy makes slow work explicit. `cabal build all` (including
the real example executables) runs only on **Run workflow** with
`full_validation=true`; the default is false. Normal pushes/PRs do not run it in
another job. The fixture suites detect domain/WAI/SQL-rendering regressions;
they do not prove actual database execution or executable startup. Full SQL/HTTP
integration remains the explicit local `bash scripts/e2e.sh` entry below and is
not claimed by the full-build checkbox. Fast/full concurrency groups are separate.

Normal unit tests should use small fixtures and deterministic dependencies.
Actual SQL/HTTP integration remains `bash scripts/e2e.sh` with a temporary real
PostgreSQL cluster; it is not replaced by mocks. Real data, external APIs and
long benchmarks require an explicit purpose, invocation, resource/time bounds
and recorded evidence outside routine CI. Run `python3 -m unittest discover -s
scripts -p 'test_ci_*.py' -v` to verify selection, deletions and cumulative diffs.

The audit's 478-second job (setup 132, build 303, tests 31) is runner time, not a
bill. Savings and cache transfer/build tradeoffs require future measurement;
no Actions runs are needed for local workflow validation. For review, pass the
exact SHA, exit status, per-suite timing and log paths; reuse unchanged receipts
instead of rerunning gates or loading whole passing logs merely for a status update.
