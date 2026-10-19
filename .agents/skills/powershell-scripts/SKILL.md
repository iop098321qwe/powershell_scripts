---
name: powershell-scripts
description: >-
  Create, modify, and review PowerShell scripts in the powershell_scripts
  repository. Use for new .ps1 scripts, changes to existing Windows
  administration scripts, script parameters and help, scheduled-task
  automation, and script-specific validation. Default new scripts to
  Windows PowerShell 5.1 compatibility.
---

# powershell-scripts

## Inspect the task

1. Read applicable repository instructions and the target script before
   editing. Never read or modify `todo.txt`.
2. Identify the desired outcome, inputs, output, and execution context:
   interactive console, unattended Scheduled Task, or reusable function.
3. Determine required Windows components, modules, permissions, and whether
   elevation is needed. Ask only about choices that materially affect the
   implementation and cannot be inferred from the request or existing code.
4. Inspect the closest existing example for conventions:
   - `scheduled_task_service_restarter.ps1`: a small unattended service task.
   - `disable_ad_user.ps1`: interactive AD administration and restore details.
   - `personal_windows_setup.ps1`: parameterized Windows setup orchestration.
   Treat these as examples, not mandatory scaffolding or universal policy.

## Create or update a script

- Place standalone scripts at the repository root with descriptive
  `snake_case.ps1` filenames unless the task establishes another location.
- Use [assets/script-template.ps1](assets/script-template.ps1) for new scripts.
  Replace its example help and parameter with task-specific content. Add
  functions only when they clarify the implementation or remove repetition.
- Use four-space indentation, same-line opening braces, full cmdlet names,
  named parameters, and approved `Verb-Noun` names for helper functions.
  Use PascalCase parameters and camelCase local variables.
- Use `[CmdletBinding()]` and typed parameters where useful. Apply validation
  attributes that reflect actual accepted inputs; avoid unnecessary prompts
  when parameters can supply the values.
- Prefer single-quoted literal strings, double quotes for interpolation,
  splatting for long parameter lists, and `Join-Path` for constructed paths.
  Use `$PSScriptRoot` for script-relative resources and `-LiteralPath` when
  a user-supplied path must not be interpreted as a wildcard.
- Keep defaults and configuration easy to find. Preserve existing config
  formats, parameter names, and behavior unless the task requires a change.
- Keep scripts standalone; do not introduce a shared module or framework
  merely to reuse a small helper.

## Preserve runtime compatibility

- Default new scripts to Windows PowerShell 5.1. Add `#Requires -Version 5.1`
  when declaring that minimum; do not imply that it guarantees Windows or
  module availability.
- Avoid PowerShell 7-only syntax and commands, including ternary and null
  operators, pipeline chain operators, and `ForEach-Object -Parallel`.
- Check .NET API availability against the Windows PowerShell/.NET Framework
  target rather than assuming APIs available under `pwsh` exist in 5.1.
- Declare or check required modules and elevation when needed. Keep these
  requirements specific to the task; do not self-elevate every script.
- Avoid non-ASCII source text unless necessary. If needed, use UTF-8 with a
  BOM so Windows PowerShell 5.1 reads the source correctly.
- Make file-output encoding explicit when it matters; encoding defaults
  differ between Windows PowerShell 5.1 and PowerShell 7.

## Handle execution and failures

- Use `$ErrorActionPreference = 'Stop'` for multi-step administration scripts
  whose remaining steps depend on success. For small scripts, targeted
  `-ErrorAction Stop` can be sufficient.
- Use `try`/`catch` when adding actionable context, handling expected failures,
  or cleaning up. Use `finally` for cleanup that must always run. Do not
  swallow errors or report success after a failed operation.
- Check `$LASTEXITCODE` immediately after native programs when failure
  affects the result; PowerShell error preferences do not reliably handle
  native exit codes in Windows PowerShell 5.1.
- Keep pipeline results separate from status messages. Return objects from
  reusable functions, use `Write-Verbose` for diagnostics, and reserve
  `Write-Host` for intentional interactive presentation.
- Avoid prompts in unattended scripts. Use parameters or configuration and
  ensure failures produce an appropriate nonzero process result. Reserve
  explicit `exit` for script entry-point behavior, not helper functions.
- Make repeated execution predictable: inspect current state and skip work
  already satisfied when appropriate. Describe partial completion accurately.
- Use `SupportsShouldProcess` when requested or useful for administrative
  mutations. Guard the actual mutations with `$PSCmdlet.ShouldProcess()`;
  do not advertise `-WhatIf` support without honoring it throughout.
- Keep credentials and generated secrets out of source, ordinary logs, and
  help examples. Preserve restore information when the task requires it.

## Document usage

- Include comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, and concrete
  `.EXAMPLE` entries. Document each public parameter with `.PARAMETER`.
- State required runtime, modules, permissions, elevation, configuration,
  side effects, and output where relevant. Match examples to real behavior.
- For unattended scripts, document a quoted `powershell.exe -NoProfile
  -File` invocation and any required working directory or account setup.
  Add `docs/<hyphenated-script-name>.md` when scheduling or setup needs more
  explanation than script help can comfortably provide.
- Update directly affected documentation when changing behavior. Avoid
  unrelated release metadata and generated-site edits.

## Validate the change

1. Review the diff for unintended behavior changes, stale help, syntax only
   available after 5.1, and Windows-specific assumptions.
2. Parse changed scripts without running their operational code. Substitute
   the changed path in this command and repeat for each changed `.ps1` file:

   ```powershell
   $tokens = $null
   $parseErrors = $null
   $path = (Resolve-Path -LiteralPath './example_script.ps1').Path
   $null = [System.Management.Automation.Language.Parser]::ParseFile(
       $path, [ref]$tokens, [ref]$parseErrors
   )
   if ($parseErrors.Count -gt 0) {
       $parseErrors | Format-List
       exit 1
   }
   ```

3. If PSScriptAnalyzer is available, run it on changed scripts, investigate
   findings, and use its compatibility checks when configured. Do not
   install tools or suppress findings silently.
4. Run existing relevant tests. Add focused Pester tests for meaningful
   branching or failure behavior when warranted; mock Windows, AD, service,
   and installation operations rather than invoking them during tests.
   Keep helper tests isolated from script entry-point execution.
5. Treat `pwsh` parsing on Linux as syntax evidence only, not proof of Windows
   PowerShell 5.1 or operational compatibility. Identify required Windows
   checks that could not run. Do not execute administrative scripts merely
   to verify syntax.
6. Do not use `npm test` as PowerShell validation: the current package script
   is a failing placeholder. Report exactly which checks ran and their
   results, plus any runtime limitations.
