# ==============================================================================
#  modules/skeleton.ps1
#  Generation du squelette Python (agent/ et api/) a partir des templates.
#  Equivalent de airflow.ps1 dans MRAE Scraper (qui genere le Scrapy scraper).
# ==============================================================================

function New-NewsSkeleton {
    $base = $script:CONFIG.InstallPath

    # --- api/ ----------------------------------------------------------------
    Write-FileUTF8NoBOM "$base\api\Dockerfile"       (Get-DockerfileApiContent)
    Write-FileUTF8NoBOM "$base\api\requirements.txt" (Get-ApiRequirementsContent)
    Write-FileUTF8NoBOM "$base\api\main.py"          (Get-ApiMainPyContent)

    # --- agent/ --------------------------------------------------------------
    Write-FileUTF8NoBOM "$base\agent\Dockerfile"       (Get-DockerfileAgentContent)
    Write-FileUTF8NoBOM "$base\agent\requirements.txt" (Get-AgentRequirementsContent)
    Write-FileUTF8NoBOM "$base\agent\main.py"          (Get-AgentMainPyContent)

    # --- searxng/ ------------------------------------------------------------
    Write-FileUTF8NoBOM "$base\searxng\settings.yml"   (Get-SearxngSettingsContent)

    # --- Racine --------------------------------------------------------------
    Write-FileUTF8NoBOM "$base\.gitignore" (Get-GitignoreContent)
}