<#
.SYNOPSIS
  Delete the lab stacks in the SAFE order (PowerShell edition of destroy.sh).

.DESCRIPTION
  .\destroy.ps1           DRY RUN: shows what would be deleted
  .\destroy.ps1 -Yes      deletes: containers, compute, data, network (in that order)

  Stacks that do not exist are skipped. The S3 buckets in the data stack must be empty
  before CloudFormation can delete them, so this script empties them first.
#>
param([switch]$Yes)

$ErrorActionPreference = "Continue"
$Region = if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { "ap-southeast-2" }
$Prefix = if ($env:PREFIX) { $env:PREFIX } else { "mb" }
$Account = (& aws sts get-caller-identity --query Account --output text)
if ($LASTEXITCODE -ne 0 -or -not $Account) { Write-Host "No AWS credentials. Run 'aws configure' or 'aws sso login' first." -ForegroundColor Red; exit 1 }
$Account = $Account.Trim()

function Test-Stack($name) {
    & aws cloudformation describe-stacks --region $Region --stack-name $name *> $null
    return ($LASTEXITCODE -eq 0)
}

function Clear-Bucket($bucket) {
    & aws s3api head-bucket --bucket $bucket *> $null
    if ($LASTEXITCODE -ne 0) { return }
    Write-Host "  emptying s3://$bucket (all versions and delete markers)"
    $tmp = [System.IO.Path]::GetTempFileName()
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    while ($true) {
        $json = & aws --region $Region s3api list-object-versions --bucket $bucket --max-items 500 --output json 2>$null
        if (-not $json) { break }
        $obj = ($json -join "`n") | ConvertFrom-Json
        $items = @()
        if ($obj.Versions)      { $items += @($obj.Versions      | ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } }) }
        if ($obj.DeleteMarkers) { $items += @($obj.DeleteMarkers | ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } }) }
        if ($items.Count -eq 0) { break }
        $body = @{ Objects = $items; Quiet = $true } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($tmp, $body, $utf8)
        & aws --region $Region s3api delete-objects --bucket $bucket --delete ("file://" + ($tmp -replace '\\', '/')) --bypass-governance-retention *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] could not empty $bucket (Object Lock COMPLIANCE?)" -ForegroundColor Yellow
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return
        }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Remove-LabStack($stack) {
    if (-not (Test-Stack $stack)) { Write-Host "- ${stack}: not deployed, skipping"; return }
    Write-Host "- ${stack}: delete"
    if (-not $Yes) { return }
    & aws cloudformation delete-stack --region $Region --stack-name $stack
    & aws cloudformation wait stack-delete-complete --region $Region --stack-name $stack
    if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] $stack did not delete cleanly; check the stack events in the console" -ForegroundColor Yellow }
}

if ($Yes) { Write-Host "*** LIVE: deleting stacks in $Region ***" -ForegroundColor Red }
else      { Write-Host "*** DRY RUN: add -Yes to delete ***" -ForegroundColor Yellow }

Remove-LabStack "$Prefix-containers"

# Remove the S3 trigger first so nothing fires while the function is being deleted.
if ($Yes -and (Test-Stack "$Prefix-compute")) {
    $empty = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($empty, "{}", (New-Object System.Text.UTF8Encoding($false)))
    & aws s3api put-bucket-notification-configuration --region $Region --bucket "$Prefix-recordings-$Account" `
        --notification-configuration ("file://" + ($empty -replace '\\', '/')) *> $null
    Remove-Item $empty -Force -ErrorAction SilentlyContinue
}
Remove-LabStack "$Prefix-compute"

if ($Yes -and (Test-Stack "$Prefix-data")) {
    foreach ($b in @("recordings", "datalake", "athena-results")) { Clear-Bucket "$Prefix-$b-$Account" }
}
Remove-LabStack "$Prefix-data"
Remove-LabStack "$Prefix-network"

Write-Host ""
Write-Host "Also remove the artifact bucket if you want it gone:"
Write-Host "  aws s3 rb s3://$Prefix-cfn-artifacts-$Account-$Region --force"
Write-Host "The evidence bucket (if you enabled it) is RETAINED on purpose: Object Lock buckets are not auto-deleted."
