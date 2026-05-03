#requires -Modules dbatools, PSFramework

# Snapshots the demo database to a .bak file so the long parts of the
# rebuild (cloning ~25 repos, AST-loading ~30K functions, embedding all
# of them) don't have to be repeated. Use this AFTER you've run the
# whole setup chain at least once and the database is in a clean,
# known-good state.
#
# Both the filename and the SQL backup's Description carry the latest
# git commit hash / message / author, so it's obvious from a folder
# listing or a `Read-DbaBackupHeader` which version of the demo each
# backup represents.
#
# Pair with setup\15-restore-database.ps1.

[CmdletBinding()]
param(
    [string] $SqlInstance = "10.10.10.65",
    [pscredential] $SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword)),
    [string] $DatabaseName = 'pwsh-scripts-🤣',

    [string] $BackupRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'backups'),

    # Skip the "is the demo's runtime injection still in the table?" check.
    # Use only if you know what you're doing.
    [switch] $AllowDirty
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent

# ---- Git metadata ---------------------------------------------------------
$commitShort   = (git -C $repoRoot log -1 --format=%h).Trim()
$commitFull    = (git -C $repoRoot log -1 --format=%H).Trim()
$commitAuthor  = (git -C $repoRoot log -1 --format='%an <%ae>').Trim()
$commitDate    = (git -C $repoRoot log -1 --format=%cI).Trim()
$commitMessage = (git -C $repoRoot log -1 --format=%s).Trim()
$isDirty       = [bool](git -C $repoRoot status --porcelain)

if (-not $commitShort) {
    throw "Could not read git metadata from $repoRoot. Is this a git working copy?"
}

# ---- Pre-flight: is the database actually clean? --------------------------
$queryDefaults = @{
    SqlInstance = $SqlInstance
    Database    = $DatabaseName
}
if ($SqlCredential) { $queryDefaults.SqlCredential = $SqlCredential }

$dirty = (Invoke-DbaQuery @queryDefaults -Query @'
SELECT COUNT(*) AS C
FROM dbo.Feedback f
JOIN dbo.Customers c ON c.CustomerId = f.CustomerId
WHERE c.Name = N'Justin Grote'
  AND f.Comment LIKE N'%---END FEEDBACK---%';
'@).C

if ($dirty -gt 0 -and -not $AllowDirty) {
    throw "$dirty demo-runtime injection row(s) still in dbo.Feedback. Run demo\03-summarise-and-inject.ps1's cleanup region (or pass -AllowDirty) before backing up."
}

# ---- Build paths and metadata ---------------------------------------------
if (-not (Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

# Filesystem-safe message snippet for the filename
$msgSnippet = ($commitMessage -replace '[^\w\-]+', '-').Trim('-')
if ($msgSnippet.Length -gt 50) { $msgSnippet = $msgSnippet.Substring(0, 50).TrimEnd('-') }

$timestamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$dirtyTag       = if ($isDirty) { '-DIRTY' } else { '' }
$backupFileName = "pwsh-scripts-$timestamp-$commitShort$dirtyTag-$msgSnippet.bak"

# Full metadata goes into the SQL backup's Description so it survives
# even if the file is renamed.
$description = @"
Database:    $DatabaseName
Backed up:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Commit:      $commitFull
Author:      $commitAuthor
CommitDate:  $commitDate
Message:     $commitMessage
WorkingTree: $(if ($isDirty) { 'DIRTY (uncommitted changes)' } else { 'clean' })
"@

Write-PSFMessage -Level Host -Message "Backing up [$DatabaseName] from $SqlInstance"
Write-PSFMessage -Level Host -Message "Commit:      $commitShort  ($commitAuthor)"
Write-PSFMessage -Level Host -Message "Message:     $commitMessage"
if ($isDirty) {
    Write-PSFMessage -Level Warning -Message "Working tree has uncommitted changes — backup filename tagged DIRTY."
}
Write-PSFMessage -Level Host -Message "Target file: $backupFileName"

# ---- Run the backup -------------------------------------------------------
$backupParams = @{
    SqlInstance     = $SqlInstance
    Database        = $DatabaseName
    Path            = $BackupRoot
    FilePath        = $backupFileName
    CompressBackup  = $true
    Description     = $description
    EnableException = $true
}
if ($SqlCredential) { $backupParams.SqlCredential = $SqlCredential }

$result = Backup-DbaDatabase @backupParams

$sizeMb = [math]::Round($result.TotalSize.Megabyte, 1)
Write-PSFMessage -Level Host -Message "Done. $sizeMb MB written to $($result.Path)"
Write-PSFMessage -Level Host -Message "Restore with: .\15-restore-database.ps1"
