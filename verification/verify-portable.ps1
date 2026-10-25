param(
  [Parameter(Mandatory = $true)][string]$ExecutablePath,
  [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'qa')
)

$ErrorActionPreference = 'Stop'
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
if ([IO.Path]::GetExtension($executable) -ne '.exe') { throw '请选择析光 Windows 可执行文件。' }
$outputFolder = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputFolder) | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$smokeOutput = Join-Path $outputFolder ('portable-smoke-' + $stamp + '.json')
$verificationOutput = Join-Path $outputFolder ('portable-launch-' + $stamp + '.json')
$savedEnvironment = @{}
$removed = @()
$process = $null
$timedOut = $false
$launchedAt = [DateTime]::UtcNow.ToString('o')

try {
  foreach ($item in Get-ChildItem Env:) {
    if ($item.Name -match '^(NODE_|ELECTRON_|PYTHON)' -or $item.Name -in @('XIGUANG_DEV_URL', 'VIRTUAL_ENV', 'CONDA_PREFIX', 'CONDA_DEFAULT_ENV', 'NVM_HOME', 'NVM_SYMLINK', 'PYENV_ROOT', 'UV_PYTHON')) {
      $savedEnvironment[$item.Name] = $item.Value
      $removed += $item.Name
      [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
    }
  }
  $savedEnvironment['PATH'] = $env:PATH
  $env:PATH = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
  $isolation = [ordered]@{
    pathContainsOnlyWindowsDirectories = $true
    path = $env:PATH
    canResolveNode = [bool](Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue)
    canResolvePython = [bool](Get-Command python.exe, python3.exe, py.exe -CommandType Application -ErrorAction SilentlyContinue)
    nodeEnvironmentAbsent = -not [bool](Get-ChildItem Env: | Where-Object Name -Match '^NODE_')
    pythonEnvironmentAbsent = -not [bool](Get-ChildItem Env: | Where-Object Name -Match '^PYTHON')
    electronEnvironmentAbsent = -not [bool](Get-ChildItem Env: | Where-Object Name -Match '^ELECTRON_')
    removedEnvironmentKeys = @($removed | Sort-Object)
    cleanVirtualMachine = $false
  }
  $arguments = @('--smoke-test', ('--smoke-output="{0}"' -f $smokeOutput))
  $process = Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $executable) -WindowStyle Hidden -PassThru
  if (-not $process.WaitForExit(115000)) {
    $timedOut = $true
    $killTool = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $killTool /PID $process.Id /T /F 2>$null | Out-Null
    $process.WaitForExit(5000) | Out-Null
  }
  $process.Refresh()
  $result = if (Test-Path -LiteralPath $smokeOutput) { Get-Content -LiteralPath $smokeOutput -Raw -Encoding UTF8 | ConvertFrom-Json } else { [PSCustomObject]@{ ok = $false; error = '独立程序没有生成自检结果。' } }
  $verification = [ordered]@{
    ok = ($process.ExitCode -eq 0 -and -not $timedOut -and [bool]$result.ok -and -not $isolation.canResolveNode -and -not $isolation.canResolvePython)
    executable = $executable
    smokeOutput = $smokeOutput
    launchedAt = $launchedAt
    finishedAt = [DateTime]::UtcNow.ToString('o')
    hostIsolation = $isolation
    exitCode = $process.ExitCode
    timedOut = $timedOut
    result = $result
  }
  $json = $verification | ConvertTo-Json -Depth 64
  [IO.File]::WriteAllText($verificationOutput, $json, (New-Object Text.UTF8Encoding($false)))
  Write-Output $json
  if (-not $verification.ok) { exit 1 }
} finally {
  foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
  if ($process) { $process.Dispose() }
}
