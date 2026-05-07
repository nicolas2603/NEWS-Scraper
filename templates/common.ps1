# ==============================================================================
#  templates/common.ps1
#  Fichiers transverses au projet (ni API ni agent) : .gitignore, README, ...
# ==============================================================================

function Get-GitignoreContent {
    return @'
.env
news-config.json
.NEWS_install_state
data/
config/init.sql
__pycache__/
*.pyc
*.log
'@
}
