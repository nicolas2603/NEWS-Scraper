# ==============================================================================
#  modules/docker.ps1
#  Operations Docker : prerequis, cycle de vie, logs, reset
# ==============================================================================

# ------------------------------------------------------------------------------
#  PREREQUIS
# ------------------------------------------------------------------------------

function Test-Prerequisites {
    Write-Header "Verification des prerequis"
    $allOk = $true

    Write-Step "Docker Desktop..."
    try {
        $v = docker --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw }
        Write-OK $v
    } catch {
        Write-Fail "Docker non installe ou non demarre  ->  https://www.docker.com/products/docker-desktop"
        $allOk = $false
    }

    Write-Step "Docker Compose v2..."
    try {
        $v = docker compose version 2>&1
        if ($LASTEXITCODE -ne 0) { throw }
        Write-OK $v
    } catch {
        Write-Fail "Docker Compose v2 non disponible (inclus dans Docker Desktop >= 4.x)"
        $allOk = $false
    }

    Write-Step "Daemon Docker..."
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-OK "Daemon actif" }
    else { Write-Fail "Daemon non repond - lancez Docker Desktop" ; $allOk = $false }

    Write-Step "Reseau partage '$($script:CONFIG.SharedNetwork)'..."
    $net = docker network ls --filter "name=$($script:CONFIG.SharedNetwork)" --format "{{.Name}}" 2>&1
    if ($net -eq $script:CONFIG.SharedNetwork) {
        Write-OK "Reseau '$($script:CONFIG.SharedNetwork)' present"
    } else {
        Write-Fail "Reseau '$($script:CONFIG.SharedNetwork)' introuvable -- demarrez MRAE Scraper d'abord"
        $allOk = $false
    }

    Write-Step "PostgreSQL MRAE ($($script:CONFIG.MRAEPostgres))..."
    $pgState = docker inspect --format "{{.State.Running}}" $script:CONFIG.MRAEPostgres 2>&1
    if ($pgState -eq "true") {
        Write-OK "PostgreSQL MRAE en cours d'execution"
    } else {
        Write-Fail "PostgreSQL MRAE non accessible -- demarrez la stack MRAE"
        $allOk = $false
    }

    Write-Step "Ollama MRAE ($($script:CONFIG.MRAEOllama))..."
    $olState = docker inspect --format "{{.State.Running}}" $script:CONFIG.MRAEOllama 2>&1
    if ($olState -eq "true") {
        Write-OK "Ollama MRAE en cours d'execution"
    } else {
        Write-Warn "Ollama MRAE non accessible -- le module NLP sera indisponible"
    }

    Write-Step "Schema 'news' dans la base..."
    $schema = docker exec $script:CONFIG.MRAEPostgres psql `
        -U $script:CONFIG.DBUser -d $script:CONFIG.DBName -tAc `
        "SELECT 1 FROM information_schema.schemata WHERE schema_name='news'" 2>&1
    $schemaStr = if ($null -eq $schema) { "" } else { ([string]$schema).Trim() }
    if ($schemaStr -eq "1") {
        Write-OK "Schema 'news' present"
    } else {
        Write-Warn "Schema 'news' absent -- lancez l'option 2 (Installation)"
    }

    Write-Step "Couche SIG des communes (sig.communes)..."
    $sigCheck = docker exec $script:CONFIG.MRAEPostgres psql `
        -U $script:CONFIG.DBUser -d $script:CONFIG.DBName -tAc `
        "SELECT COUNT(*) FROM sig.communes WHERE wkb_geometry IS NOT NULL" 2>&1
    $sigStr   = if ($null -eq $sigCheck) { "" } else { ([string]$sigCheck).Trim() }
    $sigCount = 0
    if ($sigStr -match '^\d+$') { $sigCount = [int]$sigStr }
    if ($LASTEXITCODE -eq 0 -and $sigCount -gt 0) {
        Write-OK "$sigCount communes presentes dans sig.communes"
    } else {
        Write-Fail "Table 'sig.communes' absente ou vide -- importez la couche avant d'aller plus loin"
        Write-Host "         Voir README pour la commande ogr2ogr d'import" -ForegroundColor DarkGray
        $allOk = $false
    }

    Write-Host ""
    if ($allOk) { Write-Host "  Systeme pret pour l'installation." -ForegroundColor Green }
    else        { Write-Host "  Des problemes ont ete detectes. Corrigez-les avant d'installer." -ForegroundColor Red }

    return $allOk
}

# ------------------------------------------------------------------------------
#  DEMARRER / ARRETER
# ------------------------------------------------------------------------------

function Start-Stack {
    Write-Header "Demarrage de la stack"
    if (-not (Test-IsInstalled)) { Write-Fail "Stack non installee. Lancez l'option 2." ; return }

    # Verifier les dependances MRAE avant de demarrer
    $net = docker network ls --filter "name=$($script:CONFIG.SharedNetwork)" --format "{{.Name}}" 2>&1
    if ($net -ne $script:CONFIG.SharedNetwork) {
        Write-Fail "Reseau '$($script:CONFIG.SharedNetwork)' introuvable."
        Write-Info "Demarrez MRAE Scraper : .\MRAEScraper.ps1 -Start"
        return
    }
    $pgState = docker inspect --format "{{.State.Running}}" $script:CONFIG.MRAEPostgres 2>&1
    if ($pgState -ne "true") {
        Write-Fail "PostgreSQL MRAE non accessible. Demarrez la stack MRAE d'abord."
        return
    }

    Set-Location $script:CONFIG.InstallPath
    Write-Step "Demarrage des conteneurs..."
    docker compose up -d --remove-orphans
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) { Write-OK "Stack NEWS demarree" ; Show-Urls }
    else { Write-Fail "Echec du demarrage. Utilisez l'option 6 (Logs) pour diagnostiquer." }
}

function Stop-Stack {
    Write-Header "Arret de la stack NEWS Scraper"
    if (-not (Test-IsInstalled)) { Write-Fail "Stack non installee." ; return }

    Set-Location $script:CONFIG.InstallPath
    Write-Step "Arret des conteneurs..."
    docker compose down
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) { Write-OK "Stack arretee proprement." }
    else { Write-Fail "Probleme lors de l'arret." }
}

# ------------------------------------------------------------------------------
#  STATUT
# ------------------------------------------------------------------------------

function Show-Status {
    Write-Header "Statut des services"
    if (-not (Test-IsInstalled)) { Write-Fail "Stack non installee." ; return }

    Set-Location $script:CONFIG.InstallPath
    Write-Host "  Conteneurs Docker :" -ForegroundColor Cyan
    Write-Host ""
    docker compose ps --format "table {{.Name}}`t{{.Status}}`t{{.Ports}}"
    Write-Host ""

    Write-Host "  Dependances MRAE :" -ForegroundColor Cyan
    Write-Host ""

    $checks = @(
        @{ Name = "Reseau partage  "; Type = "network"; Target = $script:CONFIG.SharedNetwork },
        @{ Name = "PostgreSQL MRAE "; Type = "container"; Target = $script:CONFIG.MRAEPostgres },
        @{ Name = "Ollama MRAE     "; Type = "container"; Target = $script:CONFIG.MRAEOllama }
    )

    foreach ($c in $checks) {
        $ok = $false
        if ($c.Type -eq "network") {
            $net = docker network ls --filter "name=$($c.Target)" --format "{{.Name}}" 2>&1
            $ok  = ($net -eq $c.Target)
        } elseif ($c.Type -eq "container") {
            $state = docker inspect --format "{{.State.Running}}" $c.Target 2>&1
            $ok    = ($state -eq "true")
        }
        $status = if ($ok) { "[  OK  ]" } else { "[ DOWN ]" }
        $color  = if ($ok) { "Green"    } else { "Red"     }
        Write-Host "   " -NoNewline
        Write-Host $status -ForegroundColor $color -NoNewline
        Write-Host "  $($c.Name)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  Schema base de donnees :" -ForegroundColor Cyan
    Write-Host ""
    $schema = docker exec $script:CONFIG.MRAEPostgres psql `
        -U $script:CONFIG.DBUser -d $script:CONFIG.DBName -tAc `
        "SELECT 1 FROM information_schema.schemata WHERE schema_name='news'" 2>&1
    $schemaStr = if ($null -eq $schema) { "" } else { ([string]$schema).Trim() }
    $schemaOk  = ($schemaStr -eq "1")
    $status = if ($schemaOk) { "[  OK  ]" } else { "[ DOWN ]" }
    $color  = if ($schemaOk) { "Green"    } else { "Red"     }
    Write-Host "   " -NoNewline
    Write-Host $status -ForegroundColor $color -NoNewline
    Write-Host "  Schema 'news'" -ForegroundColor White

    Write-Host ""
    Show-Urls
}

function Show-Urls {
    Write-Host ""
    Write-Host "  URLs d'acces :" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   API NEWS     " -NoNewline -ForegroundColor Gray
    Write-Host "http://localhost:$($script:CONFIG.AgentPort)" -ForegroundColor Cyan
    Write-Host "   PostgreSQL  " -NoNewline -ForegroundColor Gray
    Write-Host "localhost (via $($script:CONFIG.MRAEPostgres))" -NoNewline -ForegroundColor Cyan
    Write-Host "  schema=news  user=$($script:CONFIG.DBUser)" -ForegroundColor DarkGray
    Write-Host ""
}

# ------------------------------------------------------------------------------
#  LOGS
# ------------------------------------------------------------------------------

function Show-Logs {
    Write-Header "Logs des services NEWS Scraper"
    if (-not (Test-IsInstalled)) { Write-Fail "Stack non installee." ; return }

    Write-Host "  Quel service ?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   1. Tous les services" -ForegroundColor White
    Write-Host "   2. Agent (news_agent)" -ForegroundColor White
    Write-Host "   3. API   (news_api)"   -ForegroundColor White
    Write-Host "   4. Redis (news_redis)" -ForegroundColor White
    Write-Host ""

    $svc = switch ((Read-Host "  Choix").Trim()) {
        "2" { "news_agent" }
        "3" { "news_api"   }
        "4" { "news_redis" }
        default { "" }
    }

    Set-Location $script:CONFIG.InstallPath
    Write-Host "" ; Write-Info "Ctrl+C pour arreter" ; Write-Host ""
    if ($svc) { docker compose logs -f --tail=100 $svc }
    else      { docker compose logs -f --tail=50 }
}

# ------------------------------------------------------------------------------
#  REINITIALISATION
# ------------------------------------------------------------------------------

function Reset-Stack {
    Write-Header "Reinitialisation de la stack NEWS Scraper"

    Write-Host ""
    Write-Host "  ATTENTION : Cette operation va :" -ForegroundColor Red
    Write-Host "   - Arreter et supprimer tous les conteneurs" -ForegroundColor Yellow
    Write-Host "   - Supprimer les volumes NEWS Scraper (Redis)" -ForegroundColor Yellow
    Write-Host "   - Supprimer le schema 'news' dans la base MRAE" -ForegroundColor Yellow
    Write-Host ""
    Write-Warn "Les donnees MRAE (schema mrae, scraper) sont PRESERVEES."
    Write-Host ""

    if ((Read-Host "  Tapez CONFIRMER pour continuer") -ne "CONFIRMER") {
        Write-Info "Reinitialisation annulee." ; return
    }

    Set-Location $script:CONFIG.InstallPath
    Write-Step "Arret et suppression des conteneurs..."
    docker compose down --volumes --remove-orphans

    Write-Step "Suppression du schema 'news'..."
    docker exec $script:CONFIG.MRAEPostgres psql `
        -U $script:CONFIG.DBUser -d $script:CONFIG.DBName `
        -c "DROP SCHEMA IF EXISTS news CASCADE;" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-OK "Schema 'news' supprime" }
    else { Write-Warn "Echec suppression schema (PostgreSQL MRAE accessible ?)" }

    if ($script:CONFIG.StateFile -and (Test-Path $script:CONFIG.StateFile)) {
        Remove-Item $script:CONFIG.StateFile -Force
    }

    Write-OK "Reinitialisation terminee."
    Write-Info "Relancez l'option 2 (Installation) pour reinstaller."
}