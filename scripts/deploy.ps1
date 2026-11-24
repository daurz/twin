
param(
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",

    [ValidatePattern("^[a-z0-9-]+$")]
    [string]$ProjectName = "twin",

    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$CommandArgs
    )

    & $Command @CommandArgs

    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

function Get-TfOutput {
    param(
        [string]$Name,
        [switch]$AllowEmpty
    )

    $value = & terraform output -raw $Name

    if ($LASTEXITCODE -ne 0) {
        throw "Terraform output '$Name' failed"
    }

    if (-not $AllowEmpty -and
        [string]::IsNullOrWhiteSpace($value)) {
        throw "Terraform output '$Name' is empty"
    }

    return $value
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot

Push-Location $ProjectRoot

try {
    Write-Host "Deploying $ProjectName to $Environment"

    # 1. Terraform initialization
    Set-Location terraform

    Invoke-Checked terraform @("init", "-input=false")

    # Check existing workspace
    $workspaces = @(& terraform workspace list)

    if ($LASTEXITCODE -ne 0) {
        throw "Cannot list Terraform workspaces"
    }

    $names = @(
        $workspaces | ForEach-Object {
            ($_ -replace '^[\s*]+', '').Trim()
        } | Where-Object { $_ }
    )

    if ($names -notcontains $Environment) {
        throw "Workspace '$Environment' does not exist. Check Terraform state first."
    }

    Invoke-Checked terraform @("workspace", "select", $Environment)

    $stateObjects = @(& terraform state list)

    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read Terraform state"
    }

    # 2. Build Lambda package
    Set-Location ../backend

    Write-Host "Building Lambda package..."
    Invoke-Checked uv @("run", "deploy.py")

    if (-not (Test-Path "lambda-deployment.zip")) {
        throw "Lambda ZIP not found"
    }

    # 3. Terraform plan
    Set-Location ../terraform

    $varArgs = @(
        "-var=project_name=$ProjectName",
        "-var=environment=$Environment"
    )

    if ($Environment -eq "prod") {
        if (-not (Test-Path "prod.tfvars")) {
            throw "prod.tfvars not found"
        }

        $varArgs += "-var-file=prod.tfvars"
    }

    Write-Host "Running Terraform plan..."

    Invoke-Checked terraform (
        @("plan", "-input=false") + $varArgs
    )

    if (-not $Apply) {
        Write-Host "Plan completed. No AWS changes applied."
        Write-Host "Review the plan, then run with -Apply."
        return
    }

    # Avoid duplicate infrastructure in an empty state
    if ($stateObjects.Count -eq 0) {
        throw "Terraform state is empty. Verify existing AWS resources before applying."
    }

    # 4. Terraform apply
    Write-Host "Applying Terraform..."

    Invoke-Checked terraform (
        @("apply", "-input=false", "-auto-approve") + $varArgs
    )

    # Required Terraform outputs
    $ApiUrl = Get-TfOutput "api_gateway_url"
    $FrontendBucket = Get-TfOutput "s3_frontend_bucket"
    $CfUrl = Get-TfOutput "cloudfront_url"
    $CustomUrl = Get-TfOutput "custom_domain_url" -AllowEmpty

    # 5. Build frontend
    Set-Location ../frontend

    Write-Host "Building frontend..."

    "NEXT_PUBLIC_API_URL=$ApiUrl" |
        Set-Content ".env.production" -Encoding utf8

    if (-not (Test-Path "package-lock.json")) {
        throw "package-lock.json not found"
    }

    Invoke-Checked npm @("ci")
    Invoke-Checked npm @("run", "build")

    if (-not (Test-Path "out/index.html")) {
        throw "Next.js static export not found"
    }

    # 6. Upload frontend to S3
    Write-Host "Uploading frontend to S3..."

    Invoke-Checked aws @(
        "s3", "sync",
        "./out",
        "s3://$FrontendBucket/",terraform state list
        "--delete"
    )

    # 7. Final summary
    Write-Host "Deployment complete!" -ForegroundColor Green
    Write-Host "CloudFront URL : $CfUrl"
    Write-Host "API Gateway    : $ApiUrl"

    if ($CustomUrl) {
        Write-Host "Custom domain  : $CustomUrl"
    }
}
finally {
    Pop-Location
}
