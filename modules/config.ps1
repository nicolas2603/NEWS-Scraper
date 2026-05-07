# ==============================================================================
#  modules/config.ps1
#  Configuration centrale de la stack NEWS Scraper
# ==============================================================================

# Fichier JSON qui persiste le chemin d installation choisi
$script:NEWS_CONFIG_FILE = Join-Path (Split-Path $PSScriptRoot -Parent) "news-config.json"

$script:CONFIG = @{
    ProjectName   = "NEWS-Scraper"
    InstallPath   = ""
    ComposeFile   = ""
    EnvFile       = ""
    StateFile     = ""

    # Reseau Docker partage avec MRAE Scraper
    SharedNetwork = "mrae_network"

    # Conteneurs MRAE reutilises
    MRAEPostgres  = "mrae_postgres"
    MRAEOllama    = "mrae_ollama"

    # Base de donnees (meme instance que MRAE, schema different)
    DBName        = "mrae_db"
    DBUser        = "mrae"
    DBSchema      = "enr_agent"

    # Port local expose par news_api
    AgentPort     = 8501
}

# ==============================================================================
#  GESTION DU CHEMIN D INSTALLATION
# ==============================================================================

function Set-NEWSInstallPaths {
    param([string]$BasePath)
    $script:CONFIG.InstallPath = $BasePath
    $script:CONFIG.ComposeFile = "$BasePath\docker-compose.yml"
    $script:CONFIG.EnvFile     = "$BasePath\.env"
    $script:CONFIG.StateFile   = "$BasePath\.NEWS_install_state"
}

function Save-NEWSInstallConfig {
    param([string]$InstallPath)
    $config = @{
        InstallPath = $InstallPath
        LastUpdate  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Version     = "1.0"
    }
    $config | ConvertTo-Json | Out-File -FilePath $script:NEWS_CONFIG_FILE -Encoding UTF8 -Force
    Write-Info "Configuration sauvegardee : $script:NEWS_CONFIG_FILE"
}

function Get-SavedNEWSInstallPath {
    if (Test-Path $script:NEWS_CONFIG_FILE) {
        try {
            $config = Get-Content $script:NEWS_CONFIG_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($config.InstallPath -and (Test-Path $config.InstallPath)) {
                return $config.InstallPath
            }
        } catch {
            Write-Warn "Impossible de lire news-config.json"
        }
    }
    return $null
}

function Get-NEWSInstallPath {
    # 1. Deja en memoire pour cette session
    if ($script:CONFIG.InstallPath -and (Test-Path $script:CONFIG.InstallPath)) {
        return $script:CONFIG.InstallPath
    }

    # 2. Sauvegarde JSON existante
    $savedPath = Get-SavedNEWSInstallPath
    if ($savedPath) {
        Write-Host ""
        Write-Host "  Installation NEWS trouvee : " -ForegroundColor DarkGray -NoNewline
        Write-Host $savedPath -ForegroundColor Green
        $confirm = Read-Host "  Utiliser ce repertoire ? (O/N)"
        if ($confirm -match '^[oO]$') {
            Set-NEWSInstallPaths -BasePath $savedPath
            return $savedPath
        }
    }

    # 3. Prompt interactif
    Write-Host ""
    Write-Host "  === REPERTOIRE D INSTALLATION ===" -ForegroundColor Cyan
    Write-Host "  Entrez le chemin complet ou installer NEWS-Scraper." -ForegroundColor White
    Write-Host "  Exemples : F:\SIG\NEWS-Scraper   C:\Projects\NEWS-Scraper" -ForegroundColor Yellow
    Write-Host ""

    do {
        $path = Read-Host "  Chemin d installation"

        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-Warn "Le chemin ne peut pas etre vide."
            continue
        }

        $path = $path.Trim().TrimEnd('\')

        try {
            $drive = Split-Path -Path $path -Qualifier
            if (-not (Test-Path $drive)) {
                Write-Warn "Le lecteur $drive n existe pas."
                continue
            }
        } catch {
            Write-Warn "Chemin invalide : $path"
            continue
        }

        Set-NEWSInstallPaths   -BasePath    $path
        Save-NEWSInstallConfig -InstallPath $path
        return $path

    } while ($true)
}
