<#
.SYNOPSIS
  CloudFormation cannot create DynamoDB ITEMS, so seed the lab data from the CLI (PowerShell edition).
  Uses made-up numbers. Replace the first with your own mobile in E.164 format
  (0421 000 000 becomes +61421000000) so the "known caller" test hits PRIORITY.
  Edit your local copy only. Never commit a real number.
#>
$ErrorActionPreference = "Continue"
$Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-southeast-2" }
$Up = if ($env:NAME_PREFIX_UPPER) { $env:NAME_PREFIX_UPPER } else { "MB" }

function Put-Item($table, $item) {
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, ($item | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    & aws dynamodb put-item --region $Region --table-name $table --item ("file://" + ($tmp -replace '\\', '/'))
    $rc = $LASTEXITCODE
    Remove-Item $tmp -Force
    if ($rc -ne 0) { Write-Host "put-item into $table failed" -ForegroundColor Red; exit 1 }
}

Put-Item "$Up-Customers" @{ phoneNumber = @{ S = "+61400000001" }; customerName = @{ S = "Alex" };  customerTier = @{ S = "PRIORITY" }; accountId = @{ S = "MB-770001" }; lineOfBusiness = @{ S = "HOME_LOAN" } }
Put-Item "$Up-Customers" @{ phoneNumber = @{ S = "+61400000002" }; customerName = @{ S = "Sarah" }; customerTier = @{ S = "GENERAL" };  accountId = @{ S = "MB-770002" }; lineOfBusiness = @{ S = "EVERYDAY" } }
# No apostrophes or ampersands in values: text-to-speech reads punctuation aloud.
Put-Item "$Up-Holidays" @{ holidayDate = @{ S = "2026-12-25" }; holidayName = @{ S = "Christmas Day" }; holidayMessage = @{ S = "our contact centre is closed today" } }
Write-Host "Seeded."
