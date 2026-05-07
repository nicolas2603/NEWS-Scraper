# ==============================================================================
#  NEWSScraper.ps1
#  Installation et gestion de la stack NEWS Scraper
#  Usage : .\NEWSScraper.ps1             -> Menu interactif
#          .\NEWSScraper.ps1 -Check      -> Verification des prerequis
#          .\NEWSScraper.ps1 -Install    -> Installation complete
#          .\NEWSScraper.ps1 -Start      -> Demarrer la stack
#          .\NEWSScraper.ps1 -Stop       -> Arreter la stack
#          .\NEWSScraper.ps1 -Status     -> Statut des services
#          .\NEWSScraper.ps1 -Logs       -> Afficher les logs
#          .\NEWSScraper.ps1 -Reset      -> Reinitialiser (DANGER)
# ==============================================================================

#Requires -Version 5.1

param(
    [switch]$Check,
    [switch]$Install,
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Logs,
    [switch]$Reset,
    [string]$InstallDir = ""
)

# --- Encodage UTF-8 (Windows) -------------------------------------------------
[Console]::OutputEncoding    = [System.Text.Encoding]::UTF8
[Console]::InputEncoding     = [System.Text.Encoding]::UTF8
$OutputEncoding              = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'UTF8'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ==============================================================================
#  DEBLOCAGE DES FICHIERS (Zone.Identifier - fichiers telecharges depuis Internet)
# ==============================================================================

$psFilesToUnblock = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($f in $psFilesToUnblock) {
    Unblock-File -Path $f.FullName -ErrorAction SilentlyContinue
}

# ==============================================================================
#  CHARGEMENT DES MODULES
#
#  REGLE PowerShell : le dot-sourcing DANS une fonction charge dans le scope
#  LOCAL de la fonction, detruit a sa sortie.
#  Tous les fichiers doivent etre charges ICI, au scope script, directement.
# ==============================================================================

$_modulesDir   = Join-Path $PSScriptRoot "modules"
$_templatesDir = Join-Path $PSScriptRoot "templates"

if (-not (Test-Path $_modulesDir)) {
    Write-Host ""
    Write-Host "  [ERREUR FATALE] Dossier 'modules' introuvable :" -ForegroundColor Red
    Write-Host "  $_modulesDir" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Structure attendue a cote de NEWSScraper.ps1 :" -ForegroundColor White
    Write-Host "    modules\    (config.ps1  docker.ps1  database.ps1  skeleton.ps1)" -ForegroundColor Cyan
    Write-Host "    templates\  (api.ps1  agent.ps1  common.ps1)" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "  Appuyez sur Entree pour quitter"
    exit 1
}
if (-not (Test-Path $_templatesDir)) {
    Write-Host ""
    Write-Host "  [ERREUR FATALE] Dossier 'templates' introuvable :" -ForegroundColor Red
    Write-Host "  $_templatesDir" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Appuyez sur Entree pour quitter"
    exit 1
}

# Modules au scope script : config en premier (definit $script:CONFIG)
foreach ($_modFile in @("config.ps1", "docker.ps1", "database.ps1", "skeleton.ps1")) {
    $_modPath = Join-Path $_modulesDir $_modFile
    if (Test-Path $_modPath) {
        . $_modPath
    } else {
        Write-Host "  [ERREUR FATALE] Module introuvable : $_modPath" -ForegroundColor Red
        Read-Host "  Appuyez sur Entree pour quitter"
        exit 1
    }
}

# Templates au scope script : Get-XXXContent disponibles partout
Get-ChildItem -Path $_templatesDir -Filter "*.ps1" | ForEach-Object {
    . $_.FullName
}

# ==============================================================================
#  UTILITAIRES - AFFICHAGE
# ==============================================================================

function Write-Step   { param([string]$Msg) Write-Host "  >> " -ForegroundColor DarkCyan  -NoNewline; Write-Host $Msg -ForegroundColor White }
function Write-OK     { param([string]$Msg) Write-Host "  [OK] " -ForegroundColor Green   -NoNewline; Write-Host $Msg -ForegroundColor White }
function Write-Warn   { param([string]$Msg) Write-Host "  [!]  " -ForegroundColor Yellow  -NoNewline; Write-Host $Msg -ForegroundColor Yellow }
function Write-Fail   { param([string]$Msg) Write-Host "  [ERR] " -ForegroundColor Red    -NoNewline; Write-Host $Msg -ForegroundColor Red }
function Write-Info   { param([string]$Msg) Write-Host "  [i]  " -ForegroundColor Cyan    -NoNewline; Write-Host $Msg -ForegroundColor Gray }

function Write-Header {
    param([string]$Title)
    $line = "-" * 68
    Write-Host ""
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ""
}

function Wait-Key {
    Write-Host ""
    Write-Host "  Appuyez sur une touche pour continuer..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Write-FileUTF8NoBOM {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ==============================================================================
#  ETAT D'INSTALLATION
# ==============================================================================

function Get-InstallState {
    if ($script:CONFIG.StateFile -and (Test-Path $script:CONFIG.StateFile)) {
        return Get-Content $script:CONFIG.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $null
}

function Save-InstallState {
    $state = @{
        InstallPath = $script:CONFIG.InstallPath
        InstalledAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Version     = "1.0.0"
    }
    $state | ConvertTo-Json | Set-Content -Path $script:CONFIG.StateFile -Encoding UTF8
}

function Test-IsInstalled {
    if (-not $script:CONFIG.ComposeFile) { return $false }
    $state = Get-InstallState
    return ($null -ne $state -and (Test-Path $script:CONFIG.ComposeFile))
}

# ==============================================================================
#  BANNER ET MENU
# ==============================================================================

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +-----------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |                                                                 |" -ForegroundColor DarkCyan
    Write-Host "  |   " -ForegroundColor DarkCyan -NoNewline
    Write-Host "NEWS SCRAPER" -ForegroundColor Cyan -NoNewline
    Write-Host "                                                  |" -ForegroundColor DarkCyan
    Write-Host "  |   " -ForegroundColor DarkCyan -NoNewline
    Write-Host "Agent de veille des projets ENR" -ForegroundColor White -NoNewline
    Write-Host "                               |" -ForegroundColor DarkCyan
    Write-Host "  |   " -ForegroundColor DarkCyan -NoNewline
    Write-Host "PostGIS partage + Ollama partage + Redis + FastAPI" -ForegroundColor Gray -NoNewline
    Write-Host "            |" -ForegroundColor DarkCyan
    Write-Host "  |                                                                 |" -ForegroundColor DarkCyan
    Write-Host "  +-----------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""

    if (Test-IsInstalled) {
        $state = Get-InstallState
        Write-Host "  Installation : " -ForegroundColor DarkGray -NoNewline
        Write-Host $state.InstallPath -ForegroundColor Green -NoNewline
        Write-Host "  (installe le $($state.InstalledAt))" -ForegroundColor DarkGray
    } else {
        Write-Host "  Statut : " -ForegroundColor DarkGray -NoNewline
        Write-Host "Non installe" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-Menu {
    Show-Banner
    Write-Host "  +-----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |  MENU PRINCIPAL                                           |" -ForegroundColor Cyan
    Write-Host "  +-----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "   " -NoNewline; Write-Host "1." -ForegroundColor Cyan -NoNewline
    Write-Host " Verifier les prerequis" -ForegroundColor White
    Write-Host "   " -NoNewline; Write-Host "2." -ForegroundColor Cyan -NoNewline
    Write-Host " Installation complete de la stack" -ForegroundColor White
    Write-Host "   " -NoNewline; Write-Host "3." -ForegroundColor Green -NoNewline
    Write-Host " Demarrer la stack" -ForegroundColor White
    Write-Host "   " -NoNewline; Write-Host "4." -ForegroundColor Yellow -NoNewline
    Write-Host " Arreter la stack" -ForegroundColor White
    Write-Host "   " -NoNewline; Write-Host "5." -ForegroundColor Cyan -NoNewline
    Write-Host " Statut des services" -ForegroundColor White
    Write-Host "   " -NoNewline; Write-Host "6." -ForegroundColor Cyan -NoNewline
    Write-Host " Afficher les logs" -ForegroundColor White
    Write-Host "   " -NoNewline; Write-Host "0." -ForegroundColor Red -NoNewline
    Write-Host " Reinitialiser  (DANGER - supprime le schema enr_agent)" -ForegroundColor White
    Write-Host ""
    Write-Host "   " -NoNewline; Write-Host "Q." -ForegroundColor DarkGray -NoNewline
    Write-Host " Quitter" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  +-----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}

# ==============================================================================
#  INSTALLATION
# ==============================================================================

function Install-Stack {
    Write-Header "Installation de la stack NEWS Scraper"

    $installDir = Get-NEWSInstallPath
    Write-Host ""
    Write-Info "Repertoire cible : $installDir"
    Write-Host ""

    if (Test-IsInstalled) {
        Write-Warn "Une installation existe deja dans : $($script:CONFIG.InstallPath)"
        $confirm = Read-Host "  Continuer et ecraser les fichiers de configuration ? (o/N)"
        if ($confirm -notmatch '^[oO]$') { Write-Info "Installation annulee." ; return }
    }

    Write-Step "Verification des prerequis..."
    if (-not (Test-Prerequisites)) {
        Write-Fail "Prerequis non satisfaits. Corrigez les erreurs et relancez."
        return
    }

    Write-Step "Creation de l'arborescence..."
    $dirs = @(
        $script:CONFIG.InstallPath,
        "$($script:CONFIG.InstallPath)\agent",
        "$($script:CONFIG.InstallPath)\api",
        "$($script:CONFIG.InstallPath)\config",
        "$($script:CONFIG.InstallPath)\data",
        "$($script:CONFIG.InstallPath)\searxng"
    )
    foreach ($d in $dirs) { Ensure-Dir $d }
    Write-OK "Arborescence creee"

    Write-Step "Configuration de la base de donnees..."
    Write-Info "Mot de passe PostgreSQL MRAE (utilisateur : $($script:CONFIG.DBUser))"
    $dbPwdSecure = Read-Host "  Mot de passe DB MRAE" -AsSecureString
    $dbPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dbPwdSecure)
    )

    Write-Step "Generation du fichier .env..."
    New-EnvFile -DBPassword $dbPwd ; Write-OK ".env genere"

    Write-Step "Generation du docker-compose.yml..."
    New-DockerCompose ; Write-OK "docker-compose.yml genere"

    Write-Step "Generation du squelette agent/ et api/..."
    New-NewsSkeleton ; Write-OK "Squelettes agent/ et api/ generes"

    Write-Step "Generation du script SQL d'initialisation..."
    New-InitSQL ; Write-OK "init.sql genere"

    Write-Step "Initialisation du schema enr_agent dans la base MRAE..."
    if (-not (Invoke-InitSQL)) {
        Write-Fail "Echec de l'initialisation. Verifiez la connexion a MRAE Scraper."
        return
    }

    Write-Step "Telechargement des images Docker..."
    $images = @("python:3.11-slim", "redis:7-alpine")
    foreach ($img in $images) {
        Write-Host ""
        Write-Host "  Pulling " -ForegroundColor DarkCyan -NoNewline
        Write-Host $img -ForegroundColor Cyan
        docker pull $img
        if ($LASTEXITCODE -eq 0) { Write-OK $img }
        else { Write-Warn "Echec pull $img - sera retente au premier demarrage" }
    }

    Write-Step "Build des images NEWS Scraper..."
    Set-Location $script:CONFIG.InstallPath
    docker compose build
    if ($LASTEXITCODE -ne 0) { Write-Warn "Build incomplet - les Dockerfiles agent/ et api/ sont-ils presents ?" }
    else { Write-OK "Images construites" }

    Save-InstallState

    Write-Host ""
    Write-Host "  Installation terminee avec succes !" -ForegroundColor Green
    Write-Host ""
    Write-Info "Prochaine etape : demarrer la stack (option 3)"
    Show-Urls
}

# ==============================================================================
#  POINT D'ENTREE
# ==============================================================================

# Restaurer le chemin d'installation depuis la config JSON si disponible
$savedPath = Get-SavedNEWSInstallPath
if ($savedPath) {
    Set-NEWSInstallPaths -BasePath $savedPath
}

# Mode direct via parametres
if ($Check)   { Test-Prerequisites ; exit 0 }
if ($Install) { Install-Stack      ; exit 0 }
if ($Start)   { Start-Stack        ; exit 0 }
if ($Stop)    { Stop-Stack         ; exit 0 }
if ($Status)  { Show-Status        ; exit 0 }
if ($Logs)    { Show-Logs          ; exit 0 }
if ($Reset)   { Reset-Stack        ; exit 0 }

# Mode menu interactif (defaut)
do {
    Show-Menu
    $choice = Read-Host "  Choisissez une option"
    Write-Host ""

    switch ($choice.Trim()) {
        "1" { Test-Prerequisites ; Wait-Key }
        "2" { Install-Stack      ; Wait-Key }
        "3" { Start-Stack        ; Wait-Key }
        "4" { Stop-Stack         ; Wait-Key }
        "5" { Show-Status        ; Wait-Key }
        "6" { Show-Logs }
        "0" { Reset-Stack        ; Wait-Key }
        { $_ -in "Q","q" } {
            exit 0
        }
        default { Write-Warn "Option invalide : '$choice'" ; Start-Sleep -Seconds 1 }
    }
} while ($true)