# ==============================================================================
#  templates/searxng.ps1
#  Configuration SearXNG (settings.yml)
# ==============================================================================

function Get-SearxngSettingsContent {
    return @'
# SearXNG settings pour NEWS Scraper (usage interne, sans authentification)
# Reference : https://docs.searxng.org/admin/settings/settings.html

use_default_settings: true

general:
  debug: false
  instance_name: "NEWS Scraper SearXNG"
  privacypolicy_url: false
  donation_url: false
  contact_url: false

search:
  # Niveau de safe search : 0=off, 1=moderate, 2=strict
  safe_search: 0
  autocomplete: ''
  default_lang: 'fr'
  # Activer le format JSON pour l utilisation par l agent (desactive par defaut)
  formats:
    - html
    - json

server:
  # Clef fixe : instance privee sur reseau Docker interne, jamais exposee au web
  secret_key: "news-scraper-searxng-internal-key-change-if-needed"
  # Limiter desactive : usage interne, pas d abus a craindre
  limiter: false
  image_proxy: false
  # Acces depuis le reseau Docker : autoriser toutes origines internes
  method: "GET"

ui:
  static_use_hash: true
  default_theme: simple

# Moteurs actives pour l agregation.
#
# Choix volontairement restreint a Bing + Mojeek :
#  - Bing = le plus tolerant aux scrapers et le plus large couverture FR.
#  - Mojeek = independant (pas de dependance sur Google/Bing), pas de quota
#    aggressif sur usage modere. Backup utile.
#
# Volontairement DESACTIVES :
#  - Google : ban tres rapide via SearXNG (CAPTCHA agressif).
#  - DuckDuckGo : ban rapidement quand on enchaine plus de quelques dizaines
#    de requetes / heure depuis la meme IP. Cause majeure de l indisponibilite
#    SearXNG observee en production.
#  - Qwant : suspended_time=180 frequent.
#  - Startpage : CAPTCHA frequent.
#  - Brave : suspended_time=180 frequent.
#
# Pour reactiver un moteur (sciemment), passer 'disabled: false'.
engines:
  - name: bing
    disabled: false
    timeout: 6.0
  - name: mojeek
    disabled: true
    timeout: 6.0
  - name: google
    disabled: true
    timeout: 6.0
  - name: duckduckgo
    disabled: true
    timeout: 6.0
  - name: qwant
    disabled: true
    timeout: 6.0
  - name: startpage
    disabled: true
    timeout: 6.0
  - name: brave
    disabled: true
    timeout: 6.0
  - name: karmasearch
    disabled: true
    timeout: 6.0
  - name: wikipedia
    disabled: true
    timeout: 6.0

outgoing:
  # Delai max d une requete vers un moteur externe
  request_timeout: 6.0
  max_request_timeout: 15.0
  pool_connections: 100
  pool_maxsize: 20
  enable_http2: true
'@
}