<#
.SYNOPSIS
  Deploy ONE CloudFormation stack from this folder (PowerShell edition of deploy.sh).

.DESCRIPTION
  .\deploy.ps1 network    [Param=Value ...]   stack 1: VPC, subnets, NAT, endpoints
  .\deploy.ps1 data       [Param=Value ...]   stack 2: KMS, DynamoDB, S3, Kinesis, Athena
  .\deploy.ps1 compute    [Param=Value ...]   stack 3: Lambda, API Gateway, WAF, alarms
  .\deploy.ps1 containers [Param=Value ...]   stack 4: ECR and (optionally) EKS

  Order on the way up: data, network, compute, containers. Reverse on the way down (destroy.ps1).

  Examples:
    .\deploy.ps1 network
    .\deploy.ps1 network EnableNat=true EnableInterfaceEndpoints=true      # costs money
    .\deploy.ps1 compute ConnectInstanceId=<uuid> WireConnect=true

  Everything defaults to the cheap setting. Works in Windows PowerShell 5.1 and PowerShell 7.
  Needs the AWS CLI with credentials for the lab account.
#>
param(
    [Parameter(Position = 0)][string]$Which = "",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Extra = @()
)

$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot

$Region = if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { "ap-southeast-2" }
$Prefix = if ($env:PREFIX) { $env:PREFIX } else { "mb" }

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Invoke-Aws { & aws @args; if ($LASTEXITCODE -ne 0) { Fail "aws $($args -join ' ') failed (exit $LASTEXITCODE)" } }

switch ($Which) {
    "network"    { $template = "01-network.yaml";      $stack = "$Prefix-network" }
    "data"       { $template = "02-data.yaml";         $stack = "$Prefix-data" }
    "compute"    { $template = "03-compute-edge.yaml"; $stack = "$Prefix-compute" }
    "containers" { $template = "04-containers.yaml";   $stack = "$Prefix-containers" }
    default {
        Write-Host "Usage: .\deploy.ps1 <network|data|compute|containers> [Param=Value ...]"
        Write-Host "Order on the way up: data, network, compute, containers."
        exit 1
    }
}

$Account = (& aws sts get-caller-identity --query Account --output text)
if ($LASTEXITCODE -ne 0 -or -not $Account) { Fail "No AWS credentials. Run 'aws configure' or 'aws sso login' first." }
$Account = $Account.Trim()

$params = New-Object System.Collections.Generic.List[string]
$params.Add("Prefix=$Prefix")
if ($Which -eq "compute" -or $Which -eq "containers") {
    $params.Add("NetworkStackName=$Prefix-network")
    $params.Add("DataStackName=$Prefix-data")
}

if ($Which -eq "network") {
    # A gateway endpoint is reached through a managed PREFIX LIST of the service's addresses.
    $s3pl = (& aws ec2 describe-managed-prefix-lists --region $Region `
        --filters "Name=prefix-list-name,Values=com.amazonaws.$Region.s3" `
        --query "PrefixLists[0].PrefixListId" --output text).Trim()
    $ddbpl = (& aws ec2 describe-managed-prefix-lists --region $Region `
        --filters "Name=prefix-list-name,Values=com.amazonaws.$Region.dynamodb" `
        --query "PrefixLists[0].PrefixListId" --output text).Trim()
    if (-not $s3pl -or $s3pl -eq "None" -or -not $ddbpl -or $ddbpl -eq "None") { Fail "Could not look up the S3/DynamoDB prefix lists." }
    $params.Add("S3PrefixListId=$s3pl")
    $params.Add("DynamoDbPrefixListId=$ddbpl")
}

# Anything the caller passed overrides the defaults above (later values win).
foreach ($e in $Extra) { if ($e) { $params.Add($e) } }

if ($Which -eq "compute") {
    # `aws cloudformation package` zips ..\app\lambdas\<name>, uploads the zips, rewrites the template.
    $artifacts = "$Prefix-cfn-artifacts-$Account-$Region"
    & aws s3api head-bucket --bucket $artifacts 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating artifact bucket $artifacts"
        if ($Region -eq "us-east-1") {
            Invoke-Aws s3api create-bucket --bucket $artifacts --region $Region | Out-Null
        } else {
            Invoke-Aws s3api create-bucket --bucket $artifacts --region $Region --create-bucket-configuration "LocationConstraint=$Region" | Out-Null
        }
        Invoke-Aws s3api put-public-access-block --bucket $artifacts --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    }
    Invoke-Aws cloudformation package --region $Region --template-file $template --s3-bucket $artifacts --output-template-file ".packaged-$template" | Out-Null
    $template = ".packaged-$template"
}

Write-Host "Deploying $stack from $template in $Region"
Invoke-Aws cloudformation deploy --region $Region --stack-name $stack --template-file $template `
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset `
    --parameter-overrides @($params)

if ($Which -eq "compute") {
    # Attach the S3 -> RecordingRouter trigger. The connect/ prefix is NOT optional: without it
    # the function fires on the objects it writes itself and recurses forever.
    $fnArn = (& aws cloudformation describe-stacks --region $Region --stack-name $stack `
        --query "Stacks[0].Outputs[?OutputKey=='RecordingRouterArn'].OutputValue" --output text).Trim()
    if (-not $fnArn -or $fnArn -eq "None") { Fail "RecordingRouterArn output not found on $stack." }
    $bucket = "$Prefix-recordings-$Account"
    $notif = @{
        LambdaFunctionConfigurations = @(@{
            LambdaFunctionArn = $fnArn
            Events            = @("s3:ObjectCreated:*")
            Filter            = @{ Key = @{ FilterRules = @(@{ Name = "prefix"; Value = "connect/" }) } }
        })
    } | ConvertTo-Json -Depth 8
    $tmp = [System.IO.Path]::GetTempFileName()
    # UTF-8 without BOM (Windows PowerShell 5.1 would otherwise write a BOM that the CLI rejects)
    [System.IO.File]::WriteAllText($tmp, $notif, (New-Object System.Text.UTF8Encoding($false)))
    $uri = "file://" + ($tmp -replace '\\', '/')
    Invoke-Aws s3api put-bucket-notification-configuration --region $Region --bucket $bucket --notification-configuration $uri
    Remove-Item $tmp -Force
    Write-Host "S3 trigger attached: s3://$bucket/connect/ -> RecordingRouter"
}

& aws cloudformation describe-stacks --region $Region --stack-name $stack --query "Stacks[0].Outputs" --output table
