# Deploy the Databricks <-> Netskope DLP On Demand (DLPoD) adapter.
#
# Self-contained: the Lambda code is inlined in the template, OAuth M2M
# (Cognito client-credentials) is provisioned automatically, and the ALB
# cert is pulled from SSM at deploy time - no S3 artifacts.
#
# Prerequisite: a DLPoD appliance already deployed and tethered to your
# Netskope tenant, reachable via an internal ALB (this repo does not deploy
# the appliance itself). Fill in .env, then run:
#
#   ./deploy-databricks-adapter.ps1
#
# See docs/databricks-adapter.md for the Databricks-side setup after this
# completes.
#
# Tags are applied via a separate `update-stack --use-previous-template`
# step, NOT via `deploy --tags` - `aws cloudformation deploy` has proven
# unreliable with tags on a stack that already carries them: it errors
# ("Tag [Key] contained invalid characters") when resupplying keys that
# already exist on the stack, and omitting --tags entirely on `deploy`
# CLEARS all existing stack tags rather than leaving them alone (unlike raw
# update-stack).

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "No .env found. Copy .env.example to .env and fill it in first."
}

Get-Content .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}
if ($env:CA_BUNDLE) { $env:AWS_CA_BUNDLE = $env:CA_BUNDLE }

$region = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-west-1' }
$stack  = if ($env:STACK_NAME) { $env:STACK_NAME } else { 'netskope-dlpod-databricks-adapter' }

foreach ($req in 'VPC_ID','LAMBDA_SUBNET_IDS') {
    if (-not (Get-Item "env:$req" -ErrorAction SilentlyContinue).Value) {
        throw "Missing required value '$req' in .env"
    }
}

$overrides = @(
    "VpcId=$env:VPC_ID",
    "LambdaSubnetIds=$env:LAMBDA_SUBNET_IDS"
)
if ($env:DLP_EVALUATION_URL)  { $overrides += "DlpEvaluationUrl=$env:DLP_EVALUATION_URL" }
if ($env:CERT_PARAMETER_NAME) { $overrides += "CertParameterName=$env:CERT_PARAMETER_NAME" }
if ($env:DEFAULT_PROFILES)    { $overrides += "DefaultProfiles=$env:DEFAULT_PROFILES" }
if ($env:GENERATE_INCIDENTS)  { $overrides += "GenerateIncidents=$env:GENERATE_INCIDENTS" }

Write-Host "Deploying stack '$stack' to $region ..."
aws cloudformation deploy `
  --template-file templates/databricks-adapter.yaml `
  --stack-name $stack `
  --capabilities CAPABILITY_IAM `
  --region $region `
  --parameter-overrides $overrides

# Optional org tagging - set any of TAG_OWNER / TAG_PROJECT_TYPE /
# TAG_COST_CENTER / TAG_STAGE / TAG_SENSITIVITY in .env to apply them.
$tagMap = @{
    owner        = $env:TAG_OWNER
    'project-type' = $env:TAG_PROJECT_TYPE
    'cost-center'  = $env:TAG_COST_CENTER
    stage        = $env:TAG_STAGE
    sensitivity  = $env:TAG_SENSITIVITY
}
$tags = $tagMap.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "Key=$($_.Key),Value=$($_.Value)" }

if ($tags) {
    $tagParams = @('DefaultProfiles','VpcId','LambdaSubnetIds','DlpEvaluationUrl','CertParameterName','GenerateIncidents') |
        ForEach-Object { "ParameterKey=$_,UsePreviousValue=true" }

    Write-Host ""
    Write-Host "Applying tags ..."
    try {
        aws cloudformation update-stack --stack-name $stack --use-previous-template `
          --tags $tags --parameters $tagParams --capabilities CAPABILITY_IAM --region $region | Out-Null
        aws cloudformation wait stack-update-complete --stack-name $stack --region $region
    } catch {
        Write-Host "No tag changes to apply (stack already tagged correctly)."
    }
}

Write-Host ""
Write-Host "Done. Stack outputs:"
aws cloudformation describe-stacks --stack-name $stack --region $region `
  --query "Stacks[0].Outputs" --output table

$outputs = aws cloudformation describe-stacks --stack-name $stack --region $region `
  --query "Stacks[0].Outputs" --output json | ConvertFrom-Json
$poolId   = ($outputs | Where-Object OutputKey -eq 'UserPoolId').OutputValue
$clientId = ($outputs | Where-Object OutputKey -eq 'OAuthClientId').OutputValue

Write-Host ""
Write-Host "OAuth Client Secret (keep this out of chat/tickets - treat as a secret):"
aws cognito-idp describe-user-pool-client --user-pool-id $poolId --client-id $clientId --region $region `
  --query "UserPoolClient.ClientSecret" --output text
