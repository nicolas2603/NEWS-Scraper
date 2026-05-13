# ==============================================================================
#  templates/searxng.ps1
#  Configuration SearXNG (settings.yml)
# ==============================================================================

function Get-SearxngSettingsContent {
    return @'
use_default_settings: true

general:
  debug: false
  instance_name: "NEWS Scraper SearXNG"
  privacypolicy_url: false
  donation_url: false
  contact_url: false

search:
  safe_search: 0
  autocomplete: ''
  default_lang: 'fr'
  formats:
    - html
    - json

server:
  secret_key: "news-scraper-searxng-internal-key-change-if-needed"
  limiter: false
  image_proxy: false
  method: "GET"

ui:
  static_use_hash: true
  default_theme: simple

# Moteurs actifs :
#
#   Bing    : large couverture FR, fiable, peu agressif sur le rate-limiting.
#   DDG     : bon recall FR, tolere ~30 req/min a 3s d intervalle.
#   Qwant   : moteur francais, meilleure couverture presse regionale FR.
#   Yahoo   : index proche de Bing, resultats complementaires.
#   Brave   : bon index FR ; suspended_time possible sous forte charge,
#             SearXNG bascule alors sur les autres moteurs automatiquement.
#   Google  : meilleur recall global mais bannit les instances SearXNG rapidement.
#             Desactiver (disabled: true) si CAPTCHA ou erreurs recurrentes.
#
# Volume : top 20 sources x 5 communes x 3s = ~300s (5 min)
engines:
  - name: bing
    disabled: false
    timeout: 6.0

  - name: duckduckgo
    disabled: false
    timeout: 6.0

  - name: qwant
    disabled: false
    timeout: 6.0

  - name: yahoo
    disabled: false
    timeout: 6.0

  - name: brave
    disabled: false
    timeout: 6.0

  - name: google
    disabled: false
    timeout: 6.0

  - name: startpage
    disabled: true

  - name: mojeek
    disabled: true

  - name: karmasearch
    disabled: true

  - name: wikipedia
    disabled: true

outgoing:
  request_timeout: 6.0
  max_request_timeout: 15.0
  pool_connections: 100
  pool_maxsize: 20
  enable_http2: true
'@
}