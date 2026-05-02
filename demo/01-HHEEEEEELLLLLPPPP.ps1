$SqlInstance = '10.10.10.65'
$DatabaseName = 'pwsh-scripts-🤣'
$SqlCredential = (New-Object pscredential -ArgumentList 'sa', (Get-Secret dbapassword))

$Connection = Connect-DbaInstance -SqlInstance $SqlInstance -Credential $SqlCredential

$cmdlets = Get-Command -CommandType Cmdlet, Function |
    Where-Object { $_.HelpUri -or $_.Description }

$rows = foreach ($c in $cmdlets) {
    $help = Get-Help $c.Name -ErrorAction SilentlyContinue
    if (-not $help) { continue }

    [PSCustomObject]@{
        Name        = $c.Name
        ModuleName  = $c.ModuleName
        Synopsis    = ($help.Synopsis    | Out-String).Trim()
        Description = ($help.Description | Out-String).Trim()
        SearchText  = "$($c.Name). $($help.Synopsis) $($help.Description)" -replace '\s+', ' '
    }
}

# Bulk insert via Write-DbaDbTableData
$rows | Write-DbaDbTableData -SqlInstance $Connection -Database $DatabaseName -Table CmdletHelp -AutoCreateTable:$false