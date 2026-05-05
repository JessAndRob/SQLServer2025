#requires -Modules PSFramework

# Clones a curated list of PSConfEU speaker repositories (and a few
# blog-classic PowerShell repos) into a local corpus directory. The
# corpus feeds demo 3 (script-function similarity).
#
# Idempotent: existing clones are skipped (or pulled with -PullExisting).
# Network errors / 404s on individual users are warned about and skipped,
# not fatal — so a typo'd handle won't abort the whole run.
#
# Run order for the demo-3 chain:
#   .\08-clone-repos.ps1
#   .\10-deploy-script-function-table.ps1
#   .\11-load-script-functions.ps1   -CorpusRoot <LocalRoot>
#   .\12-embed-script-functions.ps1
#   .\13-create-vector-index.ps1

[CmdletBinding()]
param(
    # Defaults to a sibling of the setup folder so it's easy to .gitignore.
    [string] $LocalRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts-corpus'),

    # PSConfEU speakers / well-known PowerShell community GitHub handles.
    # I'm reasonably confident about most of these; verify before depending
    # on the list and add more as you remember them.
    [string[]] $Speakers = @(
        'SteveL-MSFT',          # Steve Lee
        'IISResetMe',           # Mathias R. Jessen
        'JustinGrote',          # Justin Grote
        'jdhitsolutions',       # Jeff Hicks
        'KevinMarquette',       # Kevin Marquette
        'adamdriscoll',         # Adam Driscoll
        'jhoneill',             # James O'Neill
        'jaapbrasser',          # Jaap Brasser
        'sdwheeler',            # Sean Wheeler
        'FriedrichWeinmann',    # Friedrich Weinmann
        'gaelcolas',            # Gael Colas
        'TobiasPSP',            # Tobias Weltner
        'Jaykul',               # Joel Bennett
        'alexandair',           # Aleksandar Nikolic
        'joeyaiello',           # Joey Aiello
        'potatoqualitee',       # Chrissy LeMaire
        'SQLDBAWithABeard',     # Rob Sewell
        'jpomfret',             # Jess Pomfret
        'EvotecIT',             # Przemyslaw Klys (org)
        'psconfeu',             # PSConfEU org catch-all
        'bgelens',
        'iainbrighton',
        'RichardSiddaway'
    ),

    # Classic / blog-referenced repos — explicit so we know exactly what
    # we're pulling. Add more (e.g. older Microsoft Script Center mirrors)
    # by hand here.
    [string[]] $ClassicRepos = @(
        'PowerShell/PowerShell',
        'MicrosoftDocs/PowerShell-Docs',
        'PowerShell/Modules',
        'pester/Pester',
        'dataplat/dbatools',
        'gustavo1999/powershell-delete-duplicate-files',
        'scriptrunner/PoShCrashCourse',
        'EvotecIT/PSFilePermissions',
        'jpomfret/Scripts',
        'DarwinJS/Start-Demo',
        'SQLDBAWithABeard/OldCodeFromBlog',
        'Jaykul/powershell-1',
        'jaapbrasser/UtilityScripts',
        'fleschutz/PowerShell',
        'MScholtes/TechNet-Gallery',
        'psjamesp/MOL-Scripting',
        # Older script-heavy collections that often give entertaining matches.
        'lazywinadmin/PowerShell',
        'jdhitsolutions/ISEScriptingGeek',
        'RichardSiddaway/Blogcode',
        'bgelens/BlogItems'
    ),

    # Optional GitHub PAT — raises rate limit from 60 to 5,000 requests/hr.
    # Useful if you've recently been hammering api.github.com from this box.
    [string] $GitHubToken,

    [int]    $MaxNewestPerUser = 25,
    [int]    $MaxOldestPerUser = 5,
    [switch] $PullExisting
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $LocalRoot)) {
    Write-PSFMessage -Level Host -Message "Creating $LocalRoot"
    New-Item -ItemType Directory -Path $LocalRoot | Out-Null
}

$headers = @{ 'Accept' = 'application/vnd.github+json' }
if ($GitHubToken) { $headers['Authorization'] = "Bearer $GitHubToken" }

function Get-PowerShellRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $User,
        [int] $Max,
        [ValidateSet('updated', 'created')] [string] $Sort = 'updated',
        [ValidateSet('asc', 'desc')] [string] $Direction = 'desc'
    )

    $uri = "https://api.github.com/users/$User/repos?per_page=100&sort=$Sort&direction=$Direction"
    Write-PSFMessage -Level Verbose -Message "Listing repos for $User (sort=$Sort, direction=$Direction)"

    try {
        $repos = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
        Write-PSFMessage -Level Warning -Message ("Could not list repos for {0}: {1}" -f $User, $_.Exception.Message)
        return
    }

    $repos |
    Where-Object { -not $_.fork -and -not $_.archived } |
    Where-Object { $_.language -eq 'PowerShell' -or $_.name -match 'PowerShell|Posh|PSh' } |
    Select-Object -First $Max |
    ForEach-Object {
        [pscustomobject]@{
            Url  = $_.clone_url
            Slug = "$User`_$($_.name)"
        }
    }
}

# Build the full list of repos to clone
Write-PSFMessage -Level Host -Message "Listing newest + oldest PowerShell repos for $($Speakers.Count) speakers..."
$repoList = foreach ($user in $Speakers) {
    Get-PowerShellRepo -User $user -Max $MaxNewestPerUser -Sort updated -Direction desc
    Get-PowerShellRepo -User $user -Max $MaxOldestPerUser -Sort created -Direction asc
}

Write-PSFMessage -Level Host -Message "Adding $($ClassicRepos.Count) classic repos..."
$repoList += foreach ($repo in $ClassicRepos) {
    [pscustomobject]@{
        Url  = "https://github.com/$repo.git"
        Slug = ($repo -replace '/', '_')
    }
}

# De-duplicate repos that appear in both newest/oldest/user/classic sets.
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$repoList = foreach ($r in $repoList) {
    if ($seen.Add($r.Slug)) { $r }
}

$total = @($repoList).Count
Write-PSFMessage -Level Host -Message "Cloning $total repositories into $LocalRoot"

$i = 0
foreach ($r in $repoList) {
    $i++
    $target = Join-Path $LocalRoot $r.Slug

    if (Test-Path $target) {
        if ($PullExisting) {
            Write-PSFMessage -Level Verbose -Message "[$i/$total] git pull $($r.Slug)"
            git -C $target pull --quiet 2>&1 | Out-Null
        } else {
            Write-PSFMessage -Level Verbose -Message "[$i/$total] skip (exists): $($r.Slug)"
        }
        continue
    }

    Write-PSFMessage -Level Host -Message "[$i/$total] git clone $($r.Url)"
    git clone --depth 1 --quiet $r.Url $target 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-PSFMessage -Level Warning -Message "Clone failed for $($r.Url) (exit $LASTEXITCODE)"
    }
}

$dirCount = (Get-ChildItem -Path $LocalRoot -Directory -ErrorAction SilentlyContinue).Count
$psFileCount = (Get-ChildItem -Path $LocalRoot -Recurse -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue -File).Count

Write-PSFMessage -Level Host -Message "Done."
Write-PSFMessage -Level Host -Message "Repository directories: $dirCount"
Write-PSFMessage -Level Host -Message ".ps1 / .psm1 files:     $psFileCount"
Write-PSFMessage -Level Host -Message "Next: .\10-deploy-script-function-table.ps1"
