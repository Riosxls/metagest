# Removes old metagest-api images after a successful build, so the <none> images do not pile up.
# Keeps: metagest-api:latest, metagest-api:previous (rollback) and the tag of the image that is running.
# Then removes dangling (<none>) images that no container uses. docker never removes an image a container uses.
param([switch]$Quiet)
$ErrorActionPreference = 'Continue'
$Image = 'metagest-api'

function Get-Id([string]$ref) { $id = (& docker image inspect -f '{{.Id}}' $ref 2>$null | Select-Object -First 1); if ($LASTEXITCODE -ne 0) { $null } else { $id } }

$keepIds = @((Get-Id "${Image}:latest"), (Get-Id "${Image}:previous")) | Where-Object { $_ }
$removed = 0
foreach ($tag in @(& docker images $Image --format '{{.Tag}}' 2>$null)) {
    if ($tag -in 'latest', 'previous' -or $tag -eq '<none>') { continue }
    $id = Get-Id "${Image}:$tag"
    if ($id -and $keepIds -contains $id) { continue }
    & docker rmi "${Image}:$tag" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $removed++ }
}
& docker image prune -f 2>&1 | Out-Null
if (-not $Quiet) { Write-Host "Imagens antigas removidas: $removed tag(s); imagens sem nome (<none>) limpas." }
