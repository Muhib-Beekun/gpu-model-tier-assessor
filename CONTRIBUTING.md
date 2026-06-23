# Contributing

## Workflow

1. Fork the repository and create a feature branch.
2. Keep changes focused and include clear commit messages.
3. Update documentation when behavior or parameters change.
4. Open a pull request with testing notes and expected impact.

## Local Checks

- Validate PowerShell syntax before opening a PR:

  pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('gpu-model-tier-assessor.ps1', [ref]$null, [ref]$null)"

- Run a local dry run:

  powershell -ExecutionPolicy Bypass -File .\gpu-model-tier-assessor.ps1

## Pull Request Guidelines

- Keep PRs small and reviewable.
- Avoid unrelated refactors in the same PR.
- Include sample output snippets when changing recommendation logic.
