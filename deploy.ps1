$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Write-Host "Creating deployment..."
$deploy = aws amplify create-deployment --app-id dwklc2sf3vn8b --branch-name main --region eu-north-1 --output json 2>$null | ConvertFrom-Json
$jobId = $deploy.jobId
$zipUrl = $deploy.zipUploadUrl

Write-Host "Job ID: $jobId"
Write-Host "Uploading zip..."
Invoke-WebRequest -Uri $zipUrl -Method Put -InFile deploy.zip -UseBasicParsing
Write-Host "Upload complete. Starting deployment..."

aws amplify start-deployment --app-id dwklc2sf3vn8b --branch-name main --job-id $jobId --region eu-north-1 --output json 2>$null
Write-Host "Deployment started."
