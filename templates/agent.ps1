# ==============================================================================
#  templates/agent.ps1
#  Tout le contenu du service agent/ : Dockerfile, requirements.txt, main.py
# ==============================================================================

function Get-DockerfileAgentContent {
    return @'
FROM python:3.11-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PYTHONUNBUFFERED=1
ENV PYTHONIOENCODING=utf-8

CMD ["python", "-u", "main.py"]
'@
}

function Get-AgentRequirementsContent {
    return @'
anthropic==0.40.0
httpx==0.27.2
psycopg2-binary==2.9.9
redis==5.0.8
beautifulsoup4==4.12.3
lxml==5.3.0
trafilatura==1.12.2
loguru==0.7.2
python-dotenv==1.0.1
tenacity==8.5.0
'@
}

function Get-AgentMainPyContent {
    return @'
# -*- coding: utf-8 -*-
"""
NEWS Scraper -- Agent de recherche ENR (etape 4b-1)

Boucle principale :
  1. Attend un job dans Redis (BRPOP news:queue, bloquant)
  2. Passe le job en 'processing' et l'enrichit dans Redis
  3. Consulte news.get_best_sources() pour recuperer les sources
     pertinentes pour le (dept, enr_type) demande.
  4. Resout la liste des communes cibles dans le rayon demande via
     news.get_communes_in_radius() (fonction PostGIS basee sur sig.communes).
  5. Pour chaque source, collecte les URLs candidates :
       - source interne (is_internal)  -> requete SQL directe sur mrae.avis
       - sinon                         -> recherche SearXNG parallelisee.
  6. Fetch des URLs (HTML via trafilatura, PDF via Tika) avec cache TTL 30 j.
  7. Pre-extraction regex : pour chaque URL, detection des mots-cles ENR,
     de la commune cible, et extraction regex de (puissance, superficie,
     porteur, date). Classement en :
       - not_relevant      : pas un projet ENR dans la zone
       - extracted_direct  : au moins 2 signaux regex trouves -> candidat direct
       - needs_llm         : pertinent mais incomplet -> sera traite en 4b-2
       - internal          : avis MRAE, metadonnees deja completes
  8. Passe le job en 'done' avec URLs + stats fetch + stats extraction.

Les etapes suivantes : 4b-2 (LLM cible sur needs_llm), 4c (consolidation LLM).
"""
import os
import json
import signal
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import List, Optional
import httpx
import redis
import psycopg2
from psycopg2.extras import RealDictCursor
from loguru import logger

# ==============================================================================
#  Configuration
# ==============================================================================

REDIS_URL   = os.getenv("REDIS_URL", "redis://news_redis:6379/0")
DB_HOST     = os.getenv("DB_HOST", "mrae_postgres")
DB_PORT     = int(os.getenv("DB_PORT", 5432))
DB_NAME     = os.getenv("DB_NAME", "mrae_db")
DB_USER     = os.getenv("DB_USER", "mrae")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

QUEUE_KEY         = "news:queue"
JOB_KEY_PREFIX    = "news:job:"
JOB_TTL_DAYS      = 7
BRPOP_TIMEOUT_SEC = 5       # cycle court pour pouvoir traiter SIGTERM proprement

# --- SearXNG ------------------------------------------------------------------
# Strategie anti rate-limit : 1 requete a la fois + delai inter-requetes + cache 24h.
# Pour un job sur N communes x M sources, le debit en sortie est donc capped a
# 1 req / (SEARXNG_QUERY_DELAY_SEC) = ~30 req/min en regime nominal.
SEARXNG_URL              = os.getenv("SEARXNG_URL", "http://news_searxng:8080")
SEARXNG_TIMEOUT_SEC      = 15
SEARXNG_MAX_RESULTS      = 5      # urls gardees par requete
SEARXNG_CONCURRENCY      = int(os.getenv("SEARXNG_CONCURRENCY", "1"))
SEARXNG_QUERY_DELAY_SEC  = float(os.getenv("SEARXNG_QUERY_DELAY_SEC", "2"))
SEARXNG_CACHE_TTL_HOURS  = int(os.getenv("SEARXNG_CACHE_TTL_HOURS", "24"))

# --- Selection des communes cibles ------------------------------------------
# 0 = pas de limite (prend toutes les communes du rayon).
# Une valeur >0 tronque a N communes les plus proches.
MAX_COMMUNES_PER_JOB = int(os.getenv("MAX_COMMUNES_PER_JOB", "0"))

# --- Fetch & extraction contenu ---------------------------------------------
TIKA_URL             = os.getenv("TIKA_URL", "http://mrae_tika:9998")
FETCH_CONCURRENCY    = int(os.getenv("FETCH_CONCURRENCY", "10"))
FETCH_PER_DOMAIN_MAX = int(os.getenv("FETCH_PER_DOMAIN_MAX", "2"))
FETCH_TIMEOUT_SEC    = int(os.getenv("FETCH_TIMEOUT_SEC", "15"))
FETCH_TEXT_MAX_CHARS = int(os.getenv("FETCH_TEXT_MAX_CHARS", "50000"))
URL_CACHE_TTL_DAYS   = int(os.getenv("URL_CACHE_TTL_DAYS", "30"))

# User-Agent realiste pour les fetchs HTTP (sites institutionnels et presse).
# Quelques sites comme Ouest-France ou les prefectures bloquent les UA
# 'python-httpx/...' par defaut.
_UA_CHROME = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# ==============================================================================
#  Mapping departement -> region administrative (metropole + DOM)
#  Les noms sans accent correspondent au seed de source_coverage.region_name.
# ==============================================================================

DEPT_TO_REGION = {
    # Auvergne-Rhone-Alpes
    "001": "Auvergne-Rhone-Alpes", "003": "Auvergne-Rhone-Alpes",
    "007": "Auvergne-Rhone-Alpes", "015": "Auvergne-Rhone-Alpes",
    "026": "Auvergne-Rhone-Alpes", "038": "Auvergne-Rhone-Alpes",
    "042": "Auvergne-Rhone-Alpes", "043": "Auvergne-Rhone-Alpes",
    "063": "Auvergne-Rhone-Alpes", "069": "Auvergne-Rhone-Alpes",
    "073": "Auvergne-Rhone-Alpes", "074": "Auvergne-Rhone-Alpes",
    # Bourgogne-Franche-Comte
    "021": "Bourgogne-Franche-Comte", "025": "Bourgogne-Franche-Comte",
    "039": "Bourgogne-Franche-Comte", "058": "Bourgogne-Franche-Comte",
    "070": "Bourgogne-Franche-Comte", "071": "Bourgogne-Franche-Comte",
    "089": "Bourgogne-Franche-Comte", "090": "Bourgogne-Franche-Comte",
    # Bretagne
    "022": "Bretagne", "029": "Bretagne", "035": "Bretagne", "056": "Bretagne",
    # Centre-Val de Loire
    "018": "Centre-Val de Loire", "028": "Centre-Val de Loire",
    "036": "Centre-Val de Loire", "037": "Centre-Val de Loire",
    "041": "Centre-Val de Loire", "045": "Centre-Val de Loire",
    # Corse
    "02A": "Corse", "02B": "Corse",
    # Grand Est
    "008": "Grand Est", "010": "Grand Est", "051": "Grand Est",
    "052": "Grand Est", "054": "Grand Est", "055": "Grand Est",
    "057": "Grand Est", "067": "Grand Est", "068": "Grand Est", "088": "Grand Est",
    # Hauts-de-France
    "002": "Hauts-de-France", "059": "Hauts-de-France", "060": "Hauts-de-France",
    "062": "Hauts-de-France", "080": "Hauts-de-France",
    # Ile-de-France
    "075": "Ile-de-France", "077": "Ile-de-France", "078": "Ile-de-France",
    "091": "Ile-de-France", "092": "Ile-de-France", "093": "Ile-de-France",
    "094": "Ile-de-France", "095": "Ile-de-France",
    # Normandie
    "014": "Normandie", "027": "Normandie", "050": "Normandie",
    "061": "Normandie", "076": "Normandie",
    # Nouvelle-Aquitaine
    "016": "Nouvelle-Aquitaine", "017": "Nouvelle-Aquitaine",
    "019": "Nouvelle-Aquitaine", "023": "Nouvelle-Aquitaine",
    "024": "Nouvelle-Aquitaine", "033": "Nouvelle-Aquitaine",
    "040": "Nouvelle-Aquitaine", "047": "Nouvelle-Aquitaine",
    "064": "Nouvelle-Aquitaine", "079": "Nouvelle-Aquitaine",
    "086": "Nouvelle-Aquitaine", "087": "Nouvelle-Aquitaine",
    # Occitanie
    "009": "Occitanie", "011": "Occitanie", "012": "Occitanie",
    "030": "Occitanie", "031": "Occitanie", "032": "Occitanie",
    "034": "Occitanie", "046": "Occitanie", "048": "Occitanie",
    "065": "Occitanie", "066": "Occitanie", "081": "Occitanie", "082": "Occitanie",
    # Pays de la Loire
    "044": "Pays de la Loire", "049": "Pays de la Loire",
    "053": "Pays de la Loire", "072": "Pays de la Loire", "085": "Pays de la Loire",
    # Provence-Alpes-Cote d'Azur
    "004": "Provence-Alpes-Cote d'Azur", "005": "Provence-Alpes-Cote d'Azur",
    "006": "Provence-Alpes-Cote d'Azur", "013": "Provence-Alpes-Cote d'Azur",
    "083": "Provence-Alpes-Cote d'Azur", "084": "Provence-Alpes-Cote d'Azur",
    # Outre-mer
    "971": "Guadeloupe", "972": "Martinique", "973": "Guyane",
    "974": "La Reunion",  "976": "Mayotte",
}

def region_of(dept_code: str) -> Optional[str]:
    """Retourne le nom de la region pour un code departement, ou None si inconnu."""
    return DEPT_TO_REGION.get(dept_code)

# ==============================================================================
#  Flag d arret propre (SIGTERM de Docker)
# ==============================================================================

_shutdown = False

def _on_signal(signum, frame):
    global _shutdown
    logger.info("Signal {} recu, arret apres le job en cours".format(signum))
    _shutdown = True

signal.signal(signal.SIGTERM, _on_signal)
signal.signal(signal.SIGINT,  _on_signal)

# ==============================================================================
#  Clients
# ==============================================================================

def get_redis():
    return redis.from_url(REDIS_URL, decode_responses=True)

def get_db():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD
    )

# ==============================================================================
#  Helpers Redis/job
# ==============================================================================

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def _job_key(job_id: str) -> str:
    return "{}{}".format(JOB_KEY_PREFIX, job_id)

def _load_job(r, job_id: str) -> Optional[dict]:
    raw = r.get(_job_key(job_id))
    return json.loads(raw) if raw else None

def _save_job(r, job: dict) -> None:
    r.set(_job_key(job["job_id"]), json.dumps(job, default=str),
          ex=JOB_TTL_DAYS * 86400)

def _update_job(r, job_id: str, **fields) -> Optional[dict]:
    """Charge un job, met a jour certains champs, resauvegarde."""
    job = _load_job(r, job_id)
    if job is None:
        logger.warning("Job {} introuvable lors de la mise a jour".format(job_id))
        return None
    job.update(fields)
    job["updated_at"] = _now_iso()
    _save_job(r, job)
    return job

# ==============================================================================
#  Consultation du registre de sources
# ==============================================================================

def get_candidate_sources(dept_code: str, enr_type: str) -> List[dict]:
    """
    Retourne les sources candidates pour (dept, enr_type), classees par
    final_score decroissant.

    S appuie sur la fonction SQL news.get_best_sources() qui combine :
      - score empirique (hit_ratio * avg_quality appris via source_feedback)
      - scores theoriques (reliability, freshness, early_signal, cost)
      - affinite source<->type ENR
      - bonus geographique (dept > region > national)
      - bonus source interne (ex: MRAE_DB)

    Les sources actives et couvrant la zone apparaissent toutes, classees.
    Une source sans feedback prend sa valeur theorique uniquement : pas d effet
    'froid' punitif comme avant.
    """
    region = region_of(dept_code)
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT source_id, domain, name, source_type, signal_type,
                       is_internal, discovery_mode, index_urls,
                       hubs_discovered_at, niveau,
                       final_score::float AS final_score
                FROM news.get_best_sources(%(enr_type)s, %(region)s, %(dept)s, %(limit)s)
                """,
                {"enr_type": enr_type, "region": region,
                 "dept": dept_code, "limit": 20}
            )
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

def get_enr_label(enr_type: str) -> str:
    """Retourne le label humain du type ENR (ex: 'Photovoltaique' pour 'photovoltaique').
    Utilise pour construire des requetes web plus pertinentes, notamment pour
    'poste' qui devient 'Poste electrique'.
    """
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT label FROM news.enr_types WHERE code = %s",
                (enr_type,)
            )
            row = cur.fetchone()
            return row[0] if row else enr_type
    finally:
        conn.close()

# ==============================================================================
#  Recherche web via SearXNG
# ==============================================================================

# Verrou global pour serialiser TOUS les hits SearXNG, peu importe le caller.
# Combine avec SEARXNG_QUERY_DELAY_SEC, cela garantit que les moteurs sous-jacents
# (DDG, Bing, Wikipedia, ...) ne recoivent pas de rafale qui declencherait un ban.
_SEARXNG_LOCK         = threading.Lock()
_SEARXNG_LAST_HIT_AT  = [0.0]   # liste pour mutabilite dans la closure

def _searxng_cache_lookup(query: str) -> Optional[List[dict]]:
    """Renvoie les resultats cache si la query a ete tiree il y a moins de
    SEARXNG_CACHE_TTL_HOURS, sinon None.
    """
    try:
        conn = get_db()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT results, fetched_at
                FROM news.searxng_cache
                WHERE query = %s
                  AND fetched_at > NOW() - %s::interval
                """,
                (query, "{} hours".format(SEARXNG_CACHE_TTL_HOURS)),
            )
            row = cur.fetchone()
        conn.close()
    except Exception as e:
        logger.warning("SearXNG cache lookup KO: {}".format(e))
        return None
    if not row:
        return None
    return row["results"]

def _searxng_cache_store(query: str, results: List[dict]) -> None:
    """Persiste les resultats SearXNG dans la table cache (UPSERT)."""
    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO news.searxng_cache (query, results, n_results, fetched_at)
                VALUES (%s, %s::jsonb, %s, NOW())
                ON CONFLICT (query) DO UPDATE SET
                    results    = EXCLUDED.results,
                    n_results  = EXCLUDED.n_results,
                    fetched_at = NOW()
                """,
                (query, json.dumps(results), len(results)),
            )
            conn.commit()
        conn.close()
    except Exception as e:
        logger.warning("SearXNG cache store KO: {}".format(e))

def searxng_search(query: str, max_results: int = SEARXNG_MAX_RESULTS) -> List[dict]:
    """Interroge SearXNG (avec cache 24h + throttling) et retourne une liste de
    {url, title, snippet}. Applique la blacklist de domaines.

    Strategie :
      1. Lookup en cache : si query identique tiree il y a < SEARXNG_CACHE_TTL_HOURS,
         retourne le cache (pas de hit reseau).
      2. Sinon : prend le verrou global, attend SEARXNG_QUERY_DELAY_SEC depuis le
         dernier hit, fait la requete, met en cache, libere le verrou.

    Le verrou + delai garantit qu on ne fait JAMAIS plus de 1 req SearXNG /
    SEARXNG_QUERY_DELAY_SEC, peu importe la concurrence du worker.
    Tolerant : en cas d erreur reseau, log + retourne une liste vide.
    """
    # 1) Cache hit ?
    cached = _searxng_cache_lookup(query)
    if cached is not None:
        # On rejoue le filtrage blacklist sur les resultats (la blacklist a pu
        # changer depuis la mise en cache).
        blacklist = _get_blacklist()
        return [r for r in cached
                if r.get("url") and not _is_blacklisted(r["url"], blacklist)
               ][:max_results]

    # 2) Cache miss -- on serialise et on throttle
    with _SEARXNG_LOCK:
        elapsed = time.time() - _SEARXNG_LAST_HIT_AT[0]
        if elapsed < SEARXNG_QUERY_DELAY_SEC:
            time.sleep(SEARXNG_QUERY_DELAY_SEC - elapsed)
        try:
            resp = httpx.get(
                "{}/search".format(SEARXNG_URL),
                params={"q": query, "format": "json", "language": "fr"},
                timeout=SEARXNG_TIMEOUT_SEC,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            logger.warning("SearXNG echec sur '{}': {}".format(query, e))
            _SEARXNG_LAST_HIT_AT[0] = time.time()
            return []
        _SEARXNG_LAST_HIT_AT[0] = time.time()

    # 3) Stocke en cache la liste BRUTE (avant blacklist).
    # La blacklist peut evoluer ; on cache le brut, on filtre a la lecture.
    raw_results = []
    for r in data.get("results", []):
        url = r.get("url", "")
        if not url:
            continue
        raw_results.append({
            "url":     url,
            "title":   r.get("title", ""),
            "snippet": r.get("content", ""),
        })
    _searxng_cache_store(query, raw_results)

    # 4) Applique la blacklist au retour
    blacklist = _get_blacklist()
    return [r for r in raw_results
            if not _is_blacklisted(r["url"], blacklist)
           ][:max_results]

# --- Blacklist : cache en memoire, rafraichi avec un TTL court ---------------
_BLACKLIST_CACHE  = {"data": None, "loaded_at": 0.0}
_BLACKLIST_TTL    = 60.0   # rechargement toutes les 60s maximum

def _get_blacklist() -> set:
    """Retourne le set des patterns de domaines blacklistes.
    Cache en memoire process avec TTL court (60s) pour permettre une edition
    a chaud en base sans redemarrer l agent.
    """
    now = time.time()
    if (_BLACKLIST_CACHE["data"] is not None
            and now - _BLACKLIST_CACHE["loaded_at"] < _BLACKLIST_TTL):
        return _BLACKLIST_CACHE["data"]

    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute("SELECT domain_pattern FROM news.domain_blacklist;")
            patterns = {row[0].lower() for row in cur.fetchall()}
        conn.close()
    except Exception as e:
        logger.warning("Blacklist : echec de lecture, fallback vide ({})".format(e))
        patterns = set()

    _BLACKLIST_CACHE["data"]      = patterns
    _BLACKLIST_CACHE["loaded_at"] = now
    return patterns

def _is_blacklisted(url: str, blacklist: set) -> bool:
    """Renvoie True si l URL appartient a un domaine blackliste.
    Matching : le pattern 'xnxx.com' matche 'forum.xnxx.com' et 'www.xnxx.com'
    (suffix-match sur le netloc avec separateur de point).
    """
    if not blacklist:
        return False
    try:
        from urllib.parse import urlparse
        netloc = urlparse(url).netloc.lower()
    except Exception:
        return False
    # Match suffix sur separateur de point : 'xnxx.com' matche 'forum.xnxx.com'
    # mais pas 'fauxxnxx.com'
    for pattern in blacklist:
        if netloc == pattern or netloc.endswith("." + pattern):
            return True
    return False

def get_target_communes(
    commune:    str,
    dept_code:  str,
    radius_km:  int,
) -> List[dict]:
    """
    Retourne toutes les communes dans le rayon autour de la commune d origine.
    La commune d origine est garantie en tete (tri SQL : is_origin DESC,
    distance_m ASC).

    La liste n est pas tronquee ici : c est process_job qui choisit ce qu il
    en fait. Typiquement la source interne MRAE utilise la liste complete
    (requete SQL gratuite) alors que les recherches SearXNG n en gardent
    que les N plus proches (pour limiter la charge moteurs).
    """
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT insee_com, nom, population, distance_m, is_origin
                FROM news.get_communes_in_radius(%s, %s, %s)
                """,
                (commune, dept_code, radius_km),
            )
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

def get_internal_avis(communes: List[dict], enr_type: str) -> List[dict]:
    """
    Retourne les avis MRAE existants dans mrae.avis qui matchent (au moins
    une des) communes cibles et le type d'ENR recherche.

    Matching combine : sur a.communes (noms) OU sur a.geom_point dans le contour
    d'une commune cible. Voir news.get_internal_avis() pour le detail SQL.
    """
    insee_codes = [c["insee_com"] for c in communes if c.get("insee_com")]
    if not insee_codes:
        return []

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT r_avis_id         AS avis_id,
                       r_reference_cle   AS reference_cle,
                       r_nom_projet      AS nom_projet,
                       r_date_avis       AS date_avis,
                       r_avis_type       AS avis_type,
                       r_maitre_ouvrage  AS maitre_ouvrage,
                       r_puissance_mw    AS puissance_mw,
                       r_superficie_ha   AS superficie_ha,
                       r_location        AS location,
                       r_poste_connexion AS poste_connexion,
                       r_resume          AS resume,
                       r_pdf_path        AS pdf_path,
                       r_matched_commune AS matched_commune
                FROM news.get_internal_avis(%s::text[], %s)
                """,
                (insee_codes, enr_type),
            )
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

def _enr_keywords_for_type(enr_type: str, enr_label: str) -> List[str]:
    """Retourne la liste de mots-cles ENR a chercher dans les titres et URLs
    pour le type donne. Combine ENR_KEYWORDS (defini plus bas, partage avec
    4b-1) et le label humain.
    """
    # ENR_KEYWORDS est defini plus bas dans le fichier (section 4b-1) mais
    # accessible au runtime via le module global.
    base = ENR_KEYWORDS.get(enr_type, []) if "ENR_KEYWORDS" in globals() else []
    if enr_label:
        base = list(base) + [enr_label]
    return base

def _normalize_text(s: str) -> str:
    """Normalisation basique pour matching de texte (commune, mots-cles).
    Lower + suppression des accents.
    """
    if not s:
        return ""
    import unicodedata
    nfd = unicodedata.normalize("NFD", s.lower())
    return "".join(c for c in nfd if unicodedata.category(c) != "Mn")

# Cache des pages d index (TTL 4h) : evite de re-fetcher la meme page
# d index plusieurs fois dans la meme journee. Cle = index_url.
_INDEX_CACHE = {}        # url -> (timestamp, list_of_hits)
_INDEX_CACHE_TTL_SEC = 4 * 3600

# Limite garde-fou pour eviter une boucle infinie en cas de site mal pagine.
_CRAWL_MAX_PAGES        = 10
_CRAWL_PAGE_STEP        = 10    # SPIP utilise (offset)/N avec N multiple de 10

def _fetch_one_index_page(page_url: str, dsfr_only: bool = False) -> tuple:
    """Fetch UNE page d index et extrait les liens utiles.
    Renvoie (hits_list, soup_or_none, used_dsfr).

    `used_dsfr` indique si l etage DSFR a produit les hits (utile pour que
    l appelant force le mode DSFR sur les pages suivantes).

    `dsfr_only=True` desactive le fallback generique. A utiliser sur les
    pages 2+ d une pagination quand on sait que la page 1 etait DSFR :
    une page 'au-dela de la fin' n a pas de cards DSFR mais a toujours
    le menu, et le fallback generique ramenerait alors le menu. Avec
    dsfr_only=True, on retourne juste une liste vide -> la pagination
    s arrete proprement.

    Strategie de selection a 2 etages :

    Etage 1 -- DSFR (Design System Francais) :
      Les sites de l administration utilisent depuis 2022 le DSFR avec des
      composants standardises. Les listings d articles utilisent
      typiquement des cards avec la classe `fr-card__link` qui pointe
      vers le contenu reel. C est notre cible prioritaire.

    Etage 2 -- fallback generique :
      Pour les sites non-DSFR (vieux SPIP, plateformes privees), on tombe
      sur la logique "tous les <a href> du domaine, longs, hors stoplist".
      Skip si dsfr_only=True.

    Cette fonction ne fait PAS de cache : c est l appelant qui agrege
    les pages et met l URL d index racine en cache.
    """
    try:
        resp = httpx.get(
            page_url,
            timeout=15.0,
            headers={"User-Agent": _UA_CHROME},
            follow_redirects=True,
        )
        resp.raise_for_status()
        html = resp.text
    except Exception as e:
        logger.warning("Crawl index KO {}: {}".format(page_url, e))
        return ([], None, False)

    from bs4 import BeautifulSoup
    from urllib.parse import urljoin, urlparse
    try:
        soup = BeautifulSoup(html, "lxml")
    except Exception:
        return ([], None, False)

    base_netloc = urlparse(page_url).netloc.lower()

    # --- Etage 1 : DSFR cards prioritaires --------------------------------
    dsfr_links = soup.select("a.fr-card__link[href]")

    hits = []
    seen = set()

    if dsfr_links:
        for a in dsfr_links:
            href = (a.get("href") or "").strip()
            if not href or href.startswith("#") or href.startswith("javascript:"):
                continue
            full_url = urljoin(page_url, href)
            try:
                netloc = urlparse(full_url).netloc.lower()
            except Exception:
                continue
            if not (netloc == base_netloc
                    or netloc.endswith("." + base_netloc.lstrip("www."))):
                continue
            text = a.get_text(strip=True)
            if not text or len(text) < 10:
                continue
            if full_url in seen:
                continue
            seen.add(full_url)
            hits.append({
                "url":     full_url,
                "title":   text[:300],
                "snippet": "",
            })
        if hits:
            return (hits, soup, True)

    # --- Etage 2 : fallback generique pour les sites non-DSFR -------------
    # Skip explicitement si dsfr_only=True (cas d une page paginee au-dela
    # de la fin reelle : les cards DSFR ont disparu mais le menu est encore
    # la, et on ne veut pas le ramener comme s il s agissait d articles).
    if dsfr_only:
        return ([], soup, False)

    stop_anchors = {
        "accueil", "contact", "mentions legales", "plan du site",
        "rss", "facebook", "twitter", "linkedin", "youtube",
        "imprimer", "partager", "telecharger", "haut de page",
        "demarches", "actualites", "agenda", "newsletter",
        "se connecter", "deconnexion", "inscription", "abonnement",
        "outils d accessibilite", "outils accessibilite",
        "version mobile", "english", "search", "recherche",
        "tout le site", "voir tout", "voir plus",
        "publications", "annonces", "etat civil",
    }

    for a in soup.select("a[href]"):
        href = (a.get("href") or "").strip()
        if not href or href.startswith("#") or href.startswith("javascript:") \
           or href.startswith("mailto:") or href.startswith("tel:"):
            continue
        full_url = urljoin(page_url, href)
        try:
            netloc = urlparse(full_url).netloc.lower()
        except Exception:
            continue
        if not (netloc == base_netloc
                or netloc.endswith("." + base_netloc.lstrip("www."))):
            continue
        text = a.get_text(strip=True)
        if not text or len(text) < 10:
            continue
        text_norm = _normalize_text(text)
        if text_norm in stop_anchors:
            continue
        if text_norm.isdigit() or text_norm in {"page suivante", "page precedente",
                                                  "suivant", "precedent",
                                                  "premiere page", "derniere page"}:
            continue
        if full_url in seen:
            continue
        seen.add(full_url)
        hits.append({
            "url":     full_url,
            "title":   text[:300],
            "snippet": "",
        })

    return (hits, soup, False)

def _crawl_index_page(index_url: str) -> List[dict]:
    """Fetch une page d index ET ses pages paginees (pattern SPIP `(offset)/N`).
    Renvoie tous les liens utiles aggreges et dedupliques.

    Strategie pagination :
      1. Fetch page 1 (URL telle que fournie)
      2. Si la page contient un lien `<a href*='(offset)/'>`, on suit la
         pagination en boucle : (offset)/10, (offset)/20, ... jusqu a
         _CRAWL_MAX_PAGES ou jusqu a une page sans nouveaux liens.
      3. Cache memoire 4h sur l URL racine (toutes pages cumulees).

    Le pattern (offset)/N est la convention SPIP, utilisee par la quasi
    totalite des sites prefecture (CMS unifie de l Etat).
    """
    # Lookup cache memoire (toutes pages cumulees)
    now = time.time()
    cached = _INDEX_CACHE.get(index_url)
    if cached and now - cached[0] < _INDEX_CACHE_TTL_SEC:
        return cached[1]

    # Page 1
    hits, soup, used_dsfr = _fetch_one_index_page(index_url)
    all_hits = list(hits)
    seen_urls = {h["url"] for h in all_hits}

    # Detection de la pagination : on cherche un lien avec (offset)/ dans le href.
    # Si oui, on enchaine page 2, 3, ... avec offsets multiples de 10.
    has_pagination = False
    if soup is not None:
        for a in soup.select("a[href]"):
            if "(offset)/" in (a.get("href") or ""):
                has_pagination = True
                break

    if has_pagination:
        # Construit l URL paginee a partir de l URL racine. On ajoute
        # /(offset)/N en suffixe (le slash de fin est tolere par SPIP).
        # Si la page 1 etait DSFR, on force dsfr_only sur les suivantes
        # pour eviter que le menu generique ne pollue les pages 'au-dela
        # de la fin'.
        base = index_url.rstrip("/")
        for page_num in range(1, _CRAWL_MAX_PAGES):
            offset = page_num * _CRAWL_PAGE_STEP
            page_url = "{}/(offset)/{}".format(base, offset)
            page_hits, _, _ = _fetch_one_index_page(page_url, dsfr_only=used_dsfr)
            # Filtre les hits deja vus en page precedente
            new_hits = [h for h in page_hits if h["url"] not in seen_urls]
            if not new_hits:
                # Plus rien de nouveau -> on arrete
                break
            all_hits.extend(new_hits)
            seen_urls.update(h["url"] for h in new_hits)

    _INDEX_CACHE[index_url] = (now, all_hits)
    return all_hits

# ==============================================================================
#  DECOUVERTE AUTOMATIQUE DES HUBS PREFECTORAUX
#
#  Adapte de tools/discover_hubs.py (script offline). On fait UNE decouverte
#  complete par prefecture quand son TTL est perime ou qu elle n a pas encore
#  ete decouverte (hubs_discovered_at IS NULL).
#
#  Strategie : on interroge le moteur de recherche interne du site prefecture
#  sur quelques termes ENR, on score les resultats, on remonte au "hub" parent
#  (un cran au-dessus dans le path), et on filtre les hubs qui contiennent
#  d autres hubs (pour ne garder que les feuilles).
#
#  Cout estime : 30-90s par prefecture (4 termes x quelques pages, avec
#  delai 3-6s entre requetes pour eviter de griller le site).
#
#  Resultat : liste d URLs (les hubs valides) qui sont stockes en base
#  dans news.sources.index_urls + hubs_discovered_at = NOW().
# ==============================================================================

HUB_TTL_DAYS               = int(os.getenv("HUB_TTL_DAYS", "30"))
_HUB_REQ_DELAY_SEC         = (3.0, 6.0)
_HUB_SEARCH_TERMS          = ["photovoltaique", "photovolta\u00efque",
                              "eolien", "\u00e9olien"]
_HUB_TIMEOUT               = 20
_HUB_MAX_OFFSET            = 200
_HUB_MIN_RESULT_SCORE      = 10
_HUB_MIN_HUB_SCORE         = 20

_HUB_ENR_KEYWORDS = [
    "photovoltaique", "photovolta\u00efque", "solaire",
    "agrivoltaique", "agrivolta\u00efque",
    "centrale photovolta\u00efque", "centrale photovoltaique",
    "parc solaire", "ferme solaire",
    "eolien", "\u00e9olien",
    "parc \u00e9olien", "parc eolien",
]
_HUB_PROJECT_KEYWORDS = [
    "projet", "implantation", "construction", "centrale", "parc",
]
_HUB_STRONG_PATTERNS = [
    "projets-photovoltaiques", "photovoltaiques", "photovolta\u00efques",
    "enquetes-publiques", "installations-classees",
]
_HUB_BAD_PATTERNS = [
    ".pdf", ".jpg", ".png", ".zip",
    "linkedin.com", "twitter.com", "facebook.com",
    "/rss", "/feed", "/actualites", "/espace-presse", "mailto:",
]

# Verrou global pour serialiser les decouvertes : si plusieurs jobs lancent
# en parallele un refresh sur la meme prefecture, un seul fait le boulot.
_HUB_DISCOVERY_LOCK = threading.Lock()
_HUB_DISCOVERY_INPROGRESS = set()  # set of domain strings

def _hub_score_result(text: str) -> int:
    """Score d un resultat de recherche prefecture (titre + description)."""
    lower = text.lower()
    enr_hits     = sum(k in lower for k in _HUB_ENR_KEYWORDS)
    project_hits = sum(k in lower for k in _HUB_PROJECT_KEYWORDS)
    score = 0
    if enr_hits >= 1:
        score += 10
    if project_hits >= 1:
        score += 5
    if enr_hits >= 1 and project_hits >= 1:
        score += 10
    return score

def _hub_is_bad_url(url: str) -> bool:
    lower = url.lower()
    return any(p in lower for p in _HUB_BAD_PATTERNS)

def _hub_get_parent(url: str) -> str:
    """Remonte d un cran dans le path (pour obtenir l URL 'hub' parent)."""
    from urllib.parse import urlparse
    p = urlparse(url)
    segs = p.path.strip("/").split("/")
    if len(segs) >= 2:
        segs = segs[:-1]
    return "{}://{}/{}".format(p.scheme, p.netloc, "/".join(segs))

def _hub_filter_parents(hubs: List[str]) -> List[str]:
    """Retire les hubs qui sont des prefixes d autres hubs (on garde les
    feuilles les plus specifiques).
    """
    from urllib.parse import urlparse
    parsed = []
    for h in hubs:
        path = urlparse(h).path.strip("/")
        segs = path.split("/") if path else []
        parsed.append({"url": h, "segs": segs})
    to_remove = set()
    for i, h1 in enumerate(parsed):
        for j, h2 in enumerate(parsed):
            if i == j:
                continue
            if len(h2["segs"]) > len(h1["segs"]) \
               and h2["segs"][:len(h1["segs"])] == h1["segs"]:
                to_remove.add(h1["url"])
    return [h for h in hubs if h not in to_remove]

def _hub_fetch(url: str) -> Optional[str]:
    """Fetch lent (avec delai aleatoire) pour la decouverte de hubs.
    Renvoie le HTML ou None.
    """
    import random as _r
    delay = _r.uniform(*_HUB_REQ_DELAY_SEC)
    time.sleep(delay)
    try:
        resp = httpx.get(
            url,
            timeout=_HUB_TIMEOUT,
            headers={"User-Agent": _UA_CHROME,
                     "Accept": "text/html",
                     "Accept-Language": "fr-FR,fr;q=0.9"},
            follow_redirects=True,
        )
        if resp.status_code != 200:
            return None
        ctype = resp.headers.get("Content-Type", "")
        if "text/html" not in ctype:
            return None
        return resp.text
    except Exception as e:
        logger.debug("HUB fetch KO {}: {}".format(url, e))
        return None

def _hub_extract_results(html: str, domain: str) -> List[dict]:
    """Parse une page de resultats de recherche prefecture (DSFR cards)."""
    from bs4 import BeautifulSoup
    from urllib.parse import urljoin
    try:
        soup = BeautifulSoup(html, "lxml")
    except Exception:
        return []
    results = []
    for card in soup.select(".fr-card"):
        title_el = card.select_one(".fr-card__title")
        if not title_el:
            continue
        link_el = title_el.find("a")
        if not link_el or not link_el.get("href"):
            continue
        href = link_el["href"]
        full_url = urljoin("https://www.{}".format(domain), href).rstrip("/")
        if _hub_is_bad_url(full_url):
            continue
        title = title_el.get_text(" ", strip=True)
        desc_el = card.select_one(".fr-card__desc")
        desc = desc_el.get_text(" ", strip=True) if desc_el else ""
        score = _hub_score_result(title + " " + desc)
        if score < _HUB_MIN_RESULT_SCORE:
            continue
        results.append({"url": full_url, "score": score})
    return results

def discover_hubs_for_domain(domain: str) -> List[str]:
    """Decouvre les hubs ENR pour UNE prefecture. Bloque ~30-90s.
    Retourne la liste des hubs valides (a stocker dans index_urls).
    """
    logger.info("[HUB] Decouverte pour {}".format(domain))
    hub_scores = {}
    for term in _HUB_SEARCH_TERMS:
        offset = 0
        while offset <= _HUB_MAX_OFFSET:
            if offset == 0:
                url = "https://www.{}/contenu/recherche?SearchText={}".format(
                    domain, term)
            else:
                url = "https://www.{}/contenu/recherche/(offset)/{}?SearchText={}".format(
                    domain, offset, term)
            html = _hub_fetch(url)
            if not html:
                break
            results = _hub_extract_results(html, domain)
            if not results:
                break
            for r in results:
                hub = _hub_get_parent(r["url"])
                bonus = 20 if any(p in hub.lower()
                                  for p in _HUB_STRONG_PATTERNS) else 0
                hub_scores[hub] = hub_scores.get(hub, 0) + r["score"] + bonus
            offset += 10
    valid = [h for h, s in hub_scores.items() if s >= _HUB_MIN_HUB_SCORE]
    filtered = _hub_filter_parents(valid)
    logger.info("[HUB] {} : {} hubs valides".format(domain, len(filtered)))
    return sorted(filtered)

def _hubs_are_stale(source: dict) -> bool:
    """Vrai si la source n a jamais ete decouverte ou si TTL depasse."""
    ts = source.get("hubs_discovered_at")
    if ts is None:
        return True
    try:
        from datetime import datetime, timezone, timedelta
        if isinstance(ts, str):
            ts = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - ts) > timedelta(days=HUB_TTL_DAYS)
    except Exception:
        return True

def _store_hubs_for_source(source_id: int, hubs: List[str]) -> None:
    """Persiste les hubs decouverts en base."""
    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE news.sources SET
                    index_urls         = %s,
                    hubs_discovered_at = NOW()
                WHERE id = %s
                """,
                (hubs, source_id),
            )
            conn.commit()
        conn.close()
    except Exception as e:
        logger.warning("[HUB] store KO source_id={}: {}".format(source_id, e))

def _ensure_hubs_fresh(source: dict) -> None:
    """Garantit que la source a des index_urls recents.
    Si stale ou vide -> lance discover_hubs_for_domain et MAJ la source
    in-memory + en base. Verrouille pour eviter les decouvertes paralleles
    sur la meme prefecture.
    """
    if not _hubs_are_stale(source):
        return
    domain = source["domain"]
    # Verrou : si une autre tache decouvre deja, on attend qu elle finisse
    # (en pratique on relit le source en base apres). Mais ici on simplifie :
    # si quelqu un d autre decouvre, on skip et on utilise les anciens hubs
    # (ou rien). Le prochain job recuperera les fresh.
    with _HUB_DISCOVERY_LOCK:
        if domain in _HUB_DISCOVERY_INPROGRESS:
            logger.info("[HUB] {} : decouverte en cours par autre tache, skip"
                        .format(domain))
            return
        _HUB_DISCOVERY_INPROGRESS.add(domain)
    try:
        hubs = discover_hubs_for_domain(domain)
        if hubs:
            _store_hubs_for_source(source["source_id"], hubs)
            source["index_urls"] = hubs   # MAJ in-memory pour ce job
        else:
            logger.warning("[HUB] {} : decouverte vide, on garde les anciens"
                           .format(domain))
    finally:
        with _HUB_DISCOVERY_LOCK:
            _HUB_DISCOVERY_INPROGRESS.discard(domain)

def _crawl_index_task(source: dict, communes: List[dict],
                      enr_keywords: List[str]) -> List[dict]:
    """Tache de discovery 'crawl_index' : fetch la (les) page(s) d index de
    la source, extrait tous les liens, puis filtre cote Python par :
      - presence du nom d une commune cible dans le titre/URL
      - presence d au moins un mot-cle ENR

    Une source peut avoir PLUSIEURS index_urls (cas des prefectures, qui
    publient sur 4-5 pages d index thematiques : Rapport-Enquetes-publiques,
    AOEP, Participation-du-public, Etudes-prealables-agricoles, etc.).
    On les fetche toutes, on agrege, on dedoublonne par URL.

    Comme c est un fetch direct (pas SearXNG), pas de quota a craindre.
    """
    index_urls = source.get("index_urls") or []
    if not index_urls:
        logger.warning("Source {} en mode crawl_index sans index_urls".format(
            source["domain"]))
        return []

    # Fetch toutes les pages d index, agregation
    raw_hits = []
    seen_urls = set()
    for url in index_urls:
        page_hits = _crawl_index_page(url)
        for h in page_hits:
            if h["url"] not in seen_urls:
                seen_urls.add(h["url"])
                raw_hits.append(h)

    if not raw_hits:
        return []

    # Normalisations pour matching
    communes_norm = [(c["nom"], _normalize_text(c["nom"])) for c in communes
                     if c.get("nom") and len(c["nom"]) >= 4]
    kw_norm = [_normalize_text(k) for k in enr_keywords if k]

    source_base = {
        "source_id": source["source_id"],
        "domain":    source["domain"],
        "niveau":    source["niveau"],
    }
    out = []
    for h in raw_hits:
        title_norm = _normalize_text(h["title"])
        url_norm   = _normalize_text(h["url"])
        # Match commune
        matched_commune = None
        for nom_orig, nom_norm in communes_norm:
            if nom_norm in title_norm or nom_norm in url_norm:
                matched_commune = nom_orig
                break
        # Match mot-cle ENR (au moins un)
        has_kw = any(k in title_norm for k in kw_norm)
        # On garde si matched_commune OU mot-cle
        if not matched_commune and not has_kw:
            continue
        out.append({
            **source_base,
            "method":          "crawl_index",
            "url":             h["url"],
            "title":           h["title"],
            "snippet":         "",
            "matched_commune": matched_commune,
        })
    return out

def _searxng_task(source: dict, commune: dict, enr_label: str) -> List[dict]:
    """Tache unitaire de recherche SearXNG pour un couple (source, commune).
    Renvoie la liste des URLs trouvees avec les metadonnees d'appariement.
    Utilise par le ThreadPoolExecutor -- doit etre thread-safe.
    """
    source_base = {
        "source_id": source["source_id"],
        "domain":    source["domain"],
        "niveau":    source["niveau"],
    }
    query = 'site:{} "{}" {}'.format(source["domain"], commune["nom"], enr_label)
    hits  = searxng_search(query)
    return [
        {**source_base,
         "method":          "searxng",
         "url":             h["url"],
         "title":           h["title"],
         "snippet":         h["snippet"],
         "matched_commune": commune["nom"]}
        for h in hits
    ]

def _searxng_free_task(free_source: dict, commune: dict, enr_label: str) -> List[dict]:
    """Recherche SearXNG libre (sans 'site:') pour une commune donnee.
    Les URLs remontees sont attribuees a la pseudo-source 'free_search'
    (domain='*'). Permet de decouvrir des URLs hors du registre declare
    (sites de mairies, presse locale non listee, etc.).
    """
    source_base = {
        "source_id": free_source["source_id"],
        "domain":    free_source["domain"],       # '*'
        "niveau":    free_source["niveau"],
    }
    query = '"{}" {} projet'.format(commune["nom"], enr_label)
    hits  = searxng_search(query)
    return [
        {**source_base,
         "method":          "free_search",
         "url":             h["url"],
         "title":           h["title"],
         "snippet":         h["snippet"],
         "matched_commune": commune["nom"]}
        for h in hits
    ]

# ==============================================================================
#  Fetch d'URLs : extraction de texte avec cache en base
# ==============================================================================

# Semaphores par domaine pour ne pas marteler un meme host en parallele.
# Lock global protegeant le dict _domain_semaphores pour eviter les races.
from threading import Lock, Semaphore
from urllib.parse import urlparse

_domain_semaphores_lock = Lock()
_domain_semaphores: dict = {}

def _get_domain_semaphore(url: str) -> Semaphore:
    """Retourne (et cree si besoin) le semaphore associe au domaine d une URL."""
    host = urlparse(url).netloc.lower()
    with _domain_semaphores_lock:
        sem = _domain_semaphores.get(host)
        if sem is None:
            sem = Semaphore(FETCH_PER_DOMAIN_MAX)
            _domain_semaphores[host] = sem
    return sem

def _url_cache_get(url: str) -> Optional[dict]:
    """Retourne l entree cache si presente et non perimee (TTL), sinon None."""
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT url, http_status, content_type, fetch_method,
                       text, text_length, fetch_duration, error, fetched_at
                FROM news.url_cache
                WHERE url = %s
                  AND fetched_at > NOW() - (%s || ' days')::interval
                """,
                (url, URL_CACHE_TTL_DAYS),
            )
            row = cur.fetchone()
            return dict(row) if row else None
    finally:
        conn.close()

def _url_cache_put(entry: dict) -> None:
    """UPSERT d une entree dans le cache (par url, mise a jour de fetched_at)."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO news.url_cache
                    (url, http_status, content_type, fetch_method,
                     text, text_length, fetch_duration, error, fetched_at)
                VALUES (%(url)s, %(http_status)s, %(content_type)s, %(fetch_method)s,
                        %(text)s, %(text_length)s, %(fetch_duration)s, %(error)s, NOW())
                ON CONFLICT (url) DO UPDATE SET
                    http_status    = EXCLUDED.http_status,
                    content_type   = EXCLUDED.content_type,
                    fetch_method   = EXCLUDED.fetch_method,
                    text           = EXCLUDED.text,
                    text_length    = EXCLUDED.text_length,
                    fetch_duration = EXCLUDED.fetch_duration,
                    error          = EXCLUDED.error,
                    fetched_at     = EXCLUDED.fetched_at
                """,
                entry,
            )
            conn.commit()
    finally:
        conn.close()

def _extract_html(html: str, url: str) -> str:
    """Extrait le texte propre d un document HTML.

    Strategie :
      1. trafilatura (mode standard, pas favor_precision) : recupere le
         corps de l article sans les menus, footers, commentaires.
      2. Si trafilatura rend moins de 500 caracteres (paywall partiel,
         layout non-standard, etc.), on fait un fallback en lisant
         directement <title>, meta-description, <h1> et le premier <p>.
         Ca permet d'avoir au moins le chapo et l'accroche, qui
         contiennent souvent l'essentiel des signaux ENR (commune,
         type, porteur, puissance).

    Le resultat est tronque a FETCH_TEXT_MAX_CHARS.
    """
    import trafilatura
    main = trafilatura.extract(
        html,
        url=url,
        include_comments=False,
        include_tables=False,
        favor_precision=False,   # mode par defaut, moins strict
    ) or ""

    # Si le corps est trop court, on tente le fallback HTML brut
    if len(main) < 500:
        fallback = _extract_html_metadata(html)
        if fallback and len(fallback) > len(main):
            main = fallback

    return main[:FETCH_TEXT_MAX_CHARS]

def _extract_html_metadata(html: str) -> str:
    """Fallback : extrait <title>, meta description, premier <h1> et premier <p>
    depuis le HTML brut. Utile pour les paywalls partiels et les layouts que
    trafilatura n aime pas.
    """
    from bs4 import BeautifulSoup
    try:
        soup = BeautifulSoup(html, "lxml")
    except Exception:
        return ""

    parts = []

    if soup.title and soup.title.string:
        parts.append(soup.title.string.strip())

    # Meta description (description classique + Open Graph)
    for selector in [
        {"name": "description"},
        {"property": "og:description"},
        {"name": "twitter:description"},
    ]:
        meta = soup.find("meta", attrs=selector)
        if meta and meta.get("content"):
            parts.append(meta["content"].strip())
            break  # une seule meta suffit

    h1 = soup.find("h1")
    if h1:
        h1_text = h1.get_text(strip=True)
        if h1_text:
            parts.append(h1_text)

    # Premier paragraphe significatif (> 80 chars) dans <main>, <article> ou body
    container = soup.find("article") or soup.find("main") or soup.body
    if container:
        for p in container.find_all("p"):
            txt = p.get_text(strip=True)
            if len(txt) >= 80:
                parts.append(txt)
                break

    return "\n".join(dict.fromkeys(parts))   # dedup en gardant l ordre

def _extract_pdf_via_tika(pdf_bytes: bytes) -> str:
    """Envoie un PDF a Tika et recupere le texte extrait.
    Le conteneur mrae_tika est partage via mrae_network.
    """
    r = httpx.put(
        TIKA_URL + "/tika",
        content=pdf_bytes,
        headers={"Accept": "text/plain"},
        timeout=60.0,   # Tika peut prendre du temps sur les gros PDFs
    )
    r.raise_for_status()
    return r.text[:FETCH_TEXT_MAX_CHARS]

def fetch_url(url: str) -> dict:
    """Fetch d une URL avec cache.
    Renvoie un dict contenant toujours les champs du cache (url, http_status,
    content_type, fetch_method, text, text_length, fetch_duration, error).
    Utilise le semaphore par domaine pour limiter la concurrence par host.
    """
    # 1. Cache lookup
    cached = _url_cache_get(url)
    if cached is not None:
        cached["from_cache"] = True
        return cached

    # 2. Fetch reseau (avec limite de concurrence par domaine)
    sem = _get_domain_semaphore(url)
    with sem:
        entry = {
            "url": url, "http_status": None, "content_type": None,
            "fetch_method": "error", "text": None, "text_length": 0,
            "fetch_duration": 0.0, "error": None,
        }
        start = time.time()
        try:
            with httpx.Client(
                follow_redirects=True,
                timeout=FETCH_TIMEOUT_SEC,
                headers={
                    # UA standard de navigateur pour eviter les blocages anti-bot.
                    # On ne contourne rien : contenus publics, veille informationnelle.
                    "User-Agent": (
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/120.0.0.0 Safari/537.36"
                    ),
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,"
                              "application/pdf;q=0.9,*/*;q=0.8",
                    "Accept-Language": "fr-FR,fr;q=0.9,en;q=0.8",
                },
            ) as client:
                resp = client.get(url)
            entry["http_status"]  = resp.status_code
            entry["content_type"] = (resp.headers.get("content-type") or "").split(";")[0].strip()

            if resp.status_code >= 400:
                entry["fetch_method"] = "error"
                entry["error"] = "HTTP {}".format(resp.status_code)
            elif entry["content_type"] == "application/pdf":
                entry["text"] = _extract_pdf_via_tika(resp.content)
                entry["fetch_method"] = "pdf"
            elif entry["content_type"].startswith("text/html"):
                entry["text"] = _extract_html(resp.text, url)
                entry["fetch_method"] = "html"
            else:
                entry["fetch_method"] = "skipped"
                entry["error"] = "content-type non supporte: {}".format(entry["content_type"])

            if entry["text"] is not None:
                entry["text_length"] = len(entry["text"])

        except httpx.TimeoutException:
            entry["error"] = "timeout"
        except httpx.RequestError as e:
            entry["error"] = "request error: {}".format(str(e)[:200])
        except Exception as e:
            entry["error"] = "unexpected: {}".format(str(e)[:200])
        finally:
            entry["fetch_duration"] = time.time() - start

    # 3. Stockage en cache :
    #   - succes (html/pdf) et skipped  -> caches (TTL plein)
    #   - HTTP 404 (URL morte)          -> cache (inutile de retenter souvent)
    #   - autres erreurs recuperables   -> PAS cachees (403 anti-bot, 429
    #     rate-limit, 5xx, timeouts, reseau...) pour permettre retry au prochain job
    cacheable = (
        entry["fetch_method"] in ("html", "pdf", "skipped")
        or entry["http_status"] == 404
    )
    if cacheable:
        try:
            _url_cache_put(entry)
        except Exception:
            logger.exception("Echec ecriture url_cache pour {}".format(url))

    entry["from_cache"] = False
    return entry

def fetch_urls_parallel(urls: List[str]) -> dict:
    """Fetch en parallele d une liste d URLs.
    Renvoie un dict { url -> entree de cache } et des statistiques agregees.
    Les URLs internal:// sont ignorees (pas de contenu a fetcher).
    """
    targets = [u for u in urls if not u.startswith("internal://")]
    results: dict = {}
    stats = {"fetched": 0, "cached": 0, "html": 0, "pdf": 0,
             "skipped": 0, "errors": 0, "total": len(targets)}

    if not targets:
        return {"results": results, "stats": stats}

    logger.info("  Fetch : {} URLs (concurrency={}, per-domain max {})".format(
        len(targets), FETCH_CONCURRENCY, FETCH_PER_DOMAIN_MAX
    ))
    start = time.time()
    with ThreadPoolExecutor(max_workers=FETCH_CONCURRENCY) as pool:
        futures = {pool.submit(fetch_url, u): u for u in targets}
        for fut in as_completed(futures):
            u = futures[fut]
            try:
                entry = fut.result()
                results[u] = entry
                if entry.get("from_cache"):
                    stats["cached"] += 1
                else:
                    stats["fetched"] += 1
                method = entry.get("fetch_method")
                if method == "html":    stats["html"]    += 1
                elif method == "pdf":   stats["pdf"]     += 1
                elif method == "skipped": stats["skipped"] += 1
                elif method == "error": stats["errors"]  += 1
            except Exception:
                logger.exception("Echec fetch {}".format(u))
                stats["errors"] += 1
    elapsed = time.time() - start
    logger.info("  Fetch : {} termines en {:.1f}s (cache={}, fetched={}, "
                "html={}, pdf={}, skipped={}, errors={})".format(
                    len(targets), elapsed,
                    stats["cached"], stats["fetched"],
                    stats["html"], stats["pdf"],
                    stats["skipped"], stats["errors"]))
    return {"results": results, "stats": stats}

# ==============================================================================
#  Etape 4b-1 : pre-extraction regex de candidats projets
# ==============================================================================
import re
import unicodedata

# Liste de porteurs ENR connus (voir DEVELOPERS.md).
# Structure : (nom_canonique, [alias_a_detecter]).
# Detection insensible a la casse et aux accents via normalisation prealable.
KNOWN_DEVELOPERS = [
    # --- Grands groupes integres ---
    ("EDF Renouvelables", ["EDF Renouvelables", "EDF EN", "EDF Energies Nouvelles"]),
    ("Engie Green",       ["Engie Green", "Engie EPS", "Engie Solar"]),
    ("TotalEnergies",     ["TotalEnergies Renouvelables", "TotalEnergies", "Total Quadran", "Quadran"]),
    ("RWE",               ["RWE Renouvelables", "RWE"]),
    ("Iberdrola",         ["Iberdrola"]),
    ("Vattenfall",        ["Vattenfall"]),
    ("Shell Energy",      ["Shell Energy"]),
    # --- Pure players francais ---
    ("Neoen",             ["Neoen"]),
    ("Voltalia",          ["Voltalia"]),
    ("Boralex",           ["Boralex"]),
    ("Valorem",           ["Groupe Valorem", "Valorem"]),
    ("Akuo Energy",       ["Akuo Energy", "Akuo"]),
    ("Reden Solar",       ["Reden Solar", "Reden"]),
    ("Urbasolar",         ["Axpo Urbasolar", "Urbasolar"]),
    ("Tenergie",          ["Tenergie", "Tenergie"]),
    ("TSE",               ["Technique Solaire", "TSE"]),
    ("Qair",              ["Groupe Qair", "Qair"]),
    ("Arkolia Energies",  ["Arkolia"]),
    ("Luxel",             ["Luxel"]),
    ("Photosol",          ["Photosol Developpement", "Photosol"]),
    ("GreenYellow",       ["GreenYellow"]),
    ("Solveo Energie",    ["Solveo Energie", "Solveo"]),
    ("UNITe",             ["UNITe", "Unite"]),
    ("Valeco",            ["Valeco"]),
    ("Kallista Energy",   ["Kallista"]),
    ("EnergieTEAM",       ["EnergieTEAM", "Energie Team"]),
    ("Ciel et Terre",     ["Ciel et Terre"]),
    # --- Developpeurs francais taille moyenne ---
    ("Energiter",         ["Energiter", "Eurocape New Energy France", "David Energies"]),
    ("Vensolair",         ["Vensolair"]),
    ("Nouvergies",        ["Nouvergies"]),
    ("IEL",               ["IEL"]),
    ("EOLFI",             ["EOLFI"]),
    ("Nass et Wind",      ["Nass & Wind", "Nass et Wind"]),
    ("Quenea",            ["Quenea", "Quenea Energies Renouvelables"]),
    ("VSB Energies",      ["VSB energies nouvelles", "VSB Energies", "VSB"]),
    ("Volkswind",         ["Volkswind"]),
    ("Sepale",            ["Sepale", "SEPALE"]),
    ("Renner Energies",   ["Renner Energies", "Renner"]),
    ("GazelEnergie",      ["GazelEnergie", "Gazel Energie"]),
    ("ABO Energy",        ["ABO Energy", "ABO Wind"]),
    ("Octopus Energy",    ["Octopus Energy"]),
    # --- Developpeurs etrangers actifs en France ---
    ("wpd France",        ["wpd France", "wpd"]),
    ("RES",               ["Renewable Energy Systems", "RES"]),
    ("BayWa r.e.",        ["BayWa r.e.", "BayWa"]),
    ("Enertrag",          ["Enertrag"]),
    ("Alterric",          ["Alterric"]),
    ("Q Energy",          ["Q Energy", "Q-Energy"]),
    ("ERG",               ["ERG"]),
    ("NTR",               ["NTR"]),
    ("Elicio",            ["Elicio"]),
    # --- Filiales grands groupes historiques ---
    ("CNR",               ["Compagnie Nationale du Rhone", "CNR"]),
    ("EDPR",              ["EDP Renewables", "EDPR"]),
    # --- Fonds et financiers majeurs ---
    ("Meridiam",          ["Meridiam"]),
    ("Mirova",            ["Mirova"]),
    ("Eurazeo",           ["Eurazeo"]),
    ("Andera Partners",   ["Andera Partners"]),
    ("Banque des Territoires", ["Banque des Territoires"]),
    ("Caisse des Depots", ["Caisse des Depots", "CDC"]),
    ("Bpifrance",         ["Bpifrance", "BPI France"]),
    ("Predica",           ["Credit Agricole Assurances", "Predica"]),
    ("AXA IM",            ["AXA Investment Managers", "AXA IM"]),
    ("Amundi",            ["Amundi Transition Energetique", "Amundi"]),
    ("Rivage Investissement", ["Rivage Investissement", "Rivage"]),
    ("Demeter IM",        ["Demeter IM", "Demeter"]),
    ("Omnes Capital",     ["Omnes Capital", "Omnes"]),
    ("Swen Capital",      ["Swen Capital Partners", "Swen"]),
    ("RGreen Invest",     ["RGreen Invest", "RGreen"]),
    ("Glennmont",         ["Glennmont Partners", "Glennmont"]),
    ("Infravia",          ["Infravia"]),
    ("Vauban",            ["Vauban Infrastructure Partners", "Vauban"]),
    ("La Nef",            ["La Nef"]),
    # --- Citoyens / cooperatifs ---
    ("Enercoop",          ["Enercoop"]),
    ("Energie Partagee",  ["Energie Partagee", "Energie Partagee Investissement", "EPI"]),
    ("EnRciT",            ["EnRciT"]),
    ("Centrales Villageoises", ["Centrales Villageoises"]),
    ("Hespul",            ["Hespul"]),
]

# Mots-cles signalant un type ENR (detection de pertinence).
# Les cles doivent matcher les codes enr_types de la base.
ENR_KEYWORDS = {
    "photovoltaique": ["photovoltaique", "photovoltaiques", "centrale solaire",
                       "parc solaire", "panneaux solaires", "panneau solaire",
                       "pv", "mwc"],
    "agrivoltaique":  ["agrivoltaique", "agrivoltaiques", "agrivoltaisme",
                       "agri-pv", "agripv"],
    "eolien":         ["eolien", "eolienne", "eoliennes", "parc eolien",
                       "turbine", "turbines", "mat", "mats"],
    "stockage":       ["stockage d'energie", "batterie", "batteries",
                       "storage", "bess"],
    "poste":          ["poste source", "poste electrique", "raccordement",
                       "transformateur"],
    "biomasse":       ["biomasse", "methanisation", "biogaz", "bois energie",
                       "cogeneration"],
    "hydraulique":    ["hydraulique", "hydroelectrique", "barrage", "turbine hydro"],
    "geothermie":     ["geothermie", "geothermique"],
    "nucleaire":      ["nucleaire", "epr", "reacteur"],
    "fossile":        ["gaz naturel", "fioul", "charbon", "turbine a gaz"],
}

# Mots-cles "signal de projet" : renforcent la pertinence si presents.
PROJECT_SIGNAL_KEYWORDS = [
    "projet", "projets",
    "enquete publique", "permis de construire", "autorisation environnementale",
    "implantation", "installation", "construction", "mise en service",
    "developpement", "developper", "developpe",
    "raccordement", "instruction", "autorisation",
    "hectares", "ha ", " mw", " mwc",
    "exploitation", "exploiter",
]

def _normalize(s: str) -> str:
    """Normalise une chaine pour matching robuste : lowercase + suppression accents.
    Garde la ponctuation et les espaces.
    """
    if not s:
        return ""
    nfd = unicodedata.normalize("NFD", s.lower())
    return "".join(c for c in nfd if unicodedata.category(c) != "Mn")

# Regex compiles une seule fois au chargement
# Puissance : "25 MW", "25.5 MWc", "25,5 megawatts"
_RE_POWER = re.compile(
    r"(\d{1,4}(?:[\.,]\d{1,3})?)\s*(mwc?\b|megawatts?\b|m\.w\.c?\.?)",
    re.IGNORECASE,
)
# Superficie : "32 ha", "32,5 hectares"
_RE_AREA = re.compile(
    r"(\d{1,4}(?:[\.,]\d{1,3})?)\s*(ha\b|hectares?\b)",
    re.IGNORECASE,
)
# Dates : 15/03/2024, 15-03-2024, 15 mars 2024
_RE_DATE_NUM  = re.compile(r"\b(\d{1,2})[\s/\-\.](\d{1,2})[\s/\-\.](\d{4})\b")
_RE_DATE_TEXT = re.compile(
    r"\b(\d{1,2})\s+(janvier|fevrier|mars|avril|mai|juin|juillet|"
    r"aout|septembre|octobre|novembre|decembre)\s+(\d{4})\b",
    re.IGNORECASE,
)

def _extract_power_mw(text_norm: str) -> Optional[float]:
    """Extrait la premiere puissance MW/MWc mentionnee, en float."""
    m = _RE_POWER.search(text_norm)
    if not m:
        return None
    raw = m.group(1).replace(",", ".")
    try:
        val = float(raw)
    except ValueError:
        return None
    # Filtre de sanite : un projet ENR en France est typiquement 0.1 a 1000 MW
    if 0.05 <= val <= 2000:
        return val
    return None

def _extract_area_ha(text_norm: str) -> Optional[float]:
    """Extrait la premiere superficie en hectares."""
    m = _RE_AREA.search(text_norm)
    if not m:
        return None
    raw = m.group(1).replace(",", ".")
    try:
        val = float(raw)
    except ValueError:
        return None
    if 0.1 <= val <= 5000:
        return val
    return None

def _extract_date(text: str) -> Optional[str]:
    """Extrait la premiere date au format ISO YYYY-MM-DD, ou None."""
    _MONTHS = {"janvier":1, "fevrier":2, "mars":3, "avril":4, "mai":5, "juin":6,
               "juillet":7, "aout":8, "septembre":9, "octobre":10,
               "novembre":11, "decembre":12}
    text_norm = _normalize(text)
    m = _RE_DATE_TEXT.search(text_norm)
    if m:
        day   = int(m.group(1))
        month = _MONTHS.get(m.group(2).lower())
        year  = int(m.group(3))
        if month and 2000 <= year <= 2030:
            return "{:04d}-{:02d}-{:02d}".format(year, month, day)
    m = _RE_DATE_NUM.search(text)
    if m:
        day, month, year = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= day <= 31 and 1 <= month <= 12 and 2000 <= year <= 2030:
            return "{:04d}-{:02d}-{:02d}".format(year, month, day)
    return None

def _detect_developer(text_norm: str) -> Optional[str]:
    """Scanne le texte (deja normalise) pour trouver un porteur connu.
    Retourne le nom canonique du premier matche, ou None.
    """
    for canonical, aliases in KNOWN_DEVELOPERS:
        for alias in aliases:
            if _normalize(alias) in text_norm:
                return canonical
    return None

def _detect_communes_in_text(text_norm: str, communes: List[dict]) -> List[str]:
    """Retourne la liste des noms de communes cibles effectivement mentionnees
    dans le texte. Utilise pour valider la pertinence geographique.
    """
    found = []
    for c in communes:
        nom_norm = _normalize(c["nom"])
        if len(nom_norm) >= 4 and nom_norm in text_norm:
            found.append(c["nom"])
    return found

def _compute_relevance(text_norm: str, communes_found: List[str],
                       enr_type: str) -> float:
    """Score de pertinence heuristique entre 0 et 1 :
       - 0.0 si texte trop court (< 200 caracteres)
       - 0.0 si aucune commune cible mentionnee
       - 0.0 si aucun mot-cle ENR du type recherche
       - sinon : somme de signaux normalisee
    """
    if len(text_norm) < 200:
        return 0.0
    if not communes_found:
        return 0.0

    enr_kws = ENR_KEYWORDS.get(enr_type, [])
    enr_hits = sum(1 for k in enr_kws if k in text_norm)
    if enr_hits == 0:
        return 0.0

    signal_hits = sum(1 for k in PROJECT_SIGNAL_KEYWORDS if k in text_norm)
    # Formule empirique : 0.4 pour le minimum viable (commune + 1 kw ENR),
    # +0.1 par signal de projet jusqu'a +0.4, +0.1 par kw ENR supplementaire.
    score = 0.4 + min(0.4, 0.1 * signal_hits) + min(0.2, 0.05 * (enr_hits - 1))
    return round(min(1.0, score), 2)

def extract_candidate_from_text(
    text:     Optional[str],
    title:    Optional[str],
    snippet:  Optional[str],
    communes: List[dict],
    enr_type: str,
    matched_commune: Optional[str] = None,
) -> dict:
    """Extraction regex d un candidat projet a partir d un texte fetche.
    Retourne un dict decrivant le statut et les champs extraits.

    Champs du retour :
      status   : not_relevant | extracted_direct | needs_llm | skipped_no_text
      method   : 'regex' | None
      is_enr_project : bool ou None (seulement True si status=extracted_direct)
      relevance_score : float 0..1
      candidate : dict projet (nullable) avec les champs extraits
    """
    if not text or len(text) < 100:
        return {"status": "skipped_no_text", "method": None,
                "is_enr_project": None, "relevance_score": 0.0,
                "candidate": None}

    # Concatene titre + snippet + texte pour l analyse, pour ne pas rater
    # un nom de porteur qui serait dans le titre et pas dans le corps.
    full = " ".join(filter(None, [title or "", snippet or "", text]))
    full_norm = _normalize(full)

    communes_found = _detect_communes_in_text(full_norm, communes)
    relevance = _compute_relevance(full_norm, communes_found, enr_type)

    if relevance < 0.4:
        return {"status": "not_relevant", "method": "regex",
                "is_enr_project": False, "relevance_score": relevance,
                "candidate": None}

    # A partir de la, le texte est pertinent. On tente l extraction directe.
    power       = _extract_power_mw(full_norm)
    area        = _extract_area_ha(full_norm)
    developer   = _detect_developer(full_norm)
    date_avis   = _extract_date(full)
    # La commune probable : matched_commune (si fournie via SearXNG) ou la 1ere trouvee
    commune_main = matched_commune or (communes_found[0] if communes_found else None)

    candidate = {
        "nom_projet":     title[:200] if title else None,  # meilleur proxy dispo
        "commune":        commune_main,
        "communes_all":   communes_found,
        "type_enr":       enr_type,
        "puissance_mw":   power,
        "superficie_ha":  area,
        "maitre_ouvrage": developer,
        "date_annonce":   date_avis,
        "statut":         None,   # heuristique non fiable, laisser au LLM
        "resume_court":   None,
        "confidence":     relevance,
    }

    # Decision : extrait direct ou renvoyer au LLM ?
    # On considere l extraction suffisante si on a au moins 2 signaux parmi :
    # (puissance, superficie, porteur).
    signals = sum(x is not None for x in (power, area, developer))
    if signals >= 2:
        return {"status": "extracted_direct", "method": "regex",
                "is_enr_project": True, "relevance_score": relevance,
                "candidate": candidate}
    # Sinon : pertinent mais incomplet, a repasser par le LLM
    return {"status": "needs_llm", "method": "regex",
            "is_enr_project": None, "relevance_score": relevance,
            "candidate": candidate}

def _extraction_from_internal(url_entry: dict, enr_type: str) -> dict:
    """Shortcut pour les URLs internal:// : les metadonnees sont deja dans
    'extra' (remplies par get_internal_avis). On fabrique un candidat
    directement sans regex ni LLM.
    """
    extra = url_entry.get("extra") or {}
    candidate = {
        "nom_projet":     url_entry.get("title"),
        "commune":        url_entry.get("matched_commune"),
        "communes_all":   [url_entry.get("matched_commune")] if url_entry.get("matched_commune") else [],
        "type_enr":       enr_type,
        "puissance_mw":   extra.get("puissance_mw"),
        "superficie_ha":  extra.get("superficie_ha"),
        "maitre_ouvrage": extra.get("maitre_ouvrage"),
        "date_annonce":   extra.get("date_avis"),
        "statut":         extra.get("avis_type"),
        "resume_court":   url_entry.get("snippet"),
        "confidence":     1.0,   # source interne = confiance max
        "mrae_ref":       extra.get("reference_cle"),
        "mrae_pdf":       extra.get("pdf_path"),
    }
    return {"status": "internal", "method": "internal",
            "is_enr_project": True, "relevance_score": 1.0,
            "candidate": candidate}

def _save_extraction(job_id: str, url: str, result: dict, duration: float,
                     error: Optional[str] = None) -> None:
    """INSERT ou UPDATE d une extraction en base."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO news.url_extractions
                    (url, job_id, status, method, is_enr_project,
                     relevance_score, candidate, duration, error)
                VALUES (%(url)s, %(job_id)s, %(status)s, %(method)s,
                        %(is_enr_project)s, %(relevance_score)s,
                        %(candidate)s::jsonb, %(duration)s, %(error)s)
                ON CONFLICT (url, job_id) DO UPDATE SET
                    status          = EXCLUDED.status,
                    method          = EXCLUDED.method,
                    is_enr_project  = EXCLUDED.is_enr_project,
                    relevance_score = EXCLUDED.relevance_score,
                    candidate       = EXCLUDED.candidate,
                    duration        = EXCLUDED.duration,
                    error           = EXCLUDED.error,
                    extracted_at    = NOW()
                """,
                {
                    "url": url, "job_id": job_id,
                    "status":          result["status"],
                    "method":          result.get("method"),
                    "is_enr_project":  result.get("is_enr_project"),
                    "relevance_score": result.get("relevance_score"),
                    "candidate":       json.dumps(result.get("candidate")) if result.get("candidate") else None,
                    "duration":        duration,
                    "error":           error,
                },
            )
            conn.commit()
    finally:
        conn.close()

def extract_all_candidates(
    job_id:        str,
    urls:          List[dict],
    fetched_by_url: dict,
    communes:      List[dict],
    enr_type:      str,
) -> dict:
    """Lance l extraction regex sur toutes les URLs du job.
    Met a jour la table news.url_extractions.
    Retourne des statistiques agregees.
    """
    stats = {
        "total":            len(urls),
        "not_relevant":     0,
        "extracted_direct": 0,
        "needs_llm":        0,
        "internal":         0,
        "skipped_no_text":  0,
        "error":            0,
    }
    start = time.time()

    for u in urls:
        url = u["url"]
        t0  = time.time()
        try:
            if url.startswith("internal://"):
                result = _extraction_from_internal(u, enr_type)
            else:
                cache_entry = fetched_by_url.get(url)
                text = cache_entry.get("text") if cache_entry else None
                result = extract_candidate_from_text(
                    text=text,
                    title=u.get("title"),
                    snippet=u.get("snippet"),
                    communes=communes,
                    enr_type=enr_type,
                    matched_commune=u.get("matched_commune"),
                )
            duration = time.time() - t0
            _save_extraction(job_id, url, result, duration)
            stats[result["status"]] = stats.get(result["status"], 0) + 1
        except Exception as e:
            duration = time.time() - t0
            logger.exception("Echec extraction pour {}".format(url))
            _save_extraction(
                job_id, url,
                {"status": "error", "method": None, "is_enr_project": None,
                 "relevance_score": 0.0, "candidate": None},
                duration,
                error=str(e)[:500],
            )
            stats["error"] += 1

    elapsed = time.time() - start
    logger.info("  Extraction regex : {} URLs en {:.1f}s "
                "(direct={}, needs_llm={}, internal={}, not_relevant={}, "
                "skipped={}, errors={})".format(
                    len(urls), elapsed,
                    stats["extracted_direct"], stats["needs_llm"],
                    stats["internal"], stats["not_relevant"],
                    stats["skipped_no_text"], stats["error"]))
    return stats

def collect_urls_for_sources(
    sources:             List[dict],
    communes_all:        List[dict],
    communes_for_search: List[dict],
    enr_type:            str,
    enr_label:           str,
) -> List[dict]:
    """
    Collecte les URLs candidates pour chaque source :
      - is_internal=true  : requete SQL directe sur toutes les communes_all
                            (requete locale, coute rien, on prend large)
      - sinon             : recherche SearXNG en parallele sur les
                            communes_for_search (tronquees aux N plus proches
                            pour limiter la charge moteurs)

    Renvoie une liste dedupliquee par URL (la premiere occurrence est gardee).
    Les resultats internes portent un champ 'extra' avec les metadonnees MRAE.
    """
    collected = []

    # --- 1. Sources internes : utiliser TOUTES les communes du rayon -----------
    internal_sources = [s for s in sources if s.get("is_internal")]
    for s in internal_sources:
        avis_list = get_internal_avis(communes_all, enr_type)
        logger.info("  internal '{}' : {} avis MRAE trouves "
                    "(sur {} communes du rayon)".format(
            s["domain"], len(avis_list), len(communes_all)
        ))
        for a in avis_list:
            collected.append({
                "source_id":       s["source_id"],
                "domain":          s["domain"],
                "niveau":          s["niveau"],
                "method":          "internal",
                "url":             "internal://{}/{}".format(s["domain"], a["avis_id"]),
                "title":           a["nom_projet"] or "(sans titre)",
                "snippet":         (a["resume"] or "")[:500],
                "matched_commune": a["matched_commune"],
                "extra": {
                    "avis_id":         a["avis_id"],
                    "reference_cle":   a["reference_cle"],
                    "date_avis":       a["date_avis"].isoformat() if a["date_avis"] else None,
                    "avis_type":       a["avis_type"],
                    "maitre_ouvrage":  a["maitre_ouvrage"],
                    "puissance_mw":    float(a["puissance_mw"]) if a["puissance_mw"] is not None else None,
                    "superficie_ha":   float(a["superficie_ha"]) if a["superficie_ha"] is not None else None,
                    "location":        a["location"],
                    "poste_connexion": a["poste_connexion"],
                    "pdf_path":        a["pdf_path"],
                },
            })

    # --- 2. Sources en mode crawl_index : fetch direct de leur page d index ----
    # Une seule requete HTTP par source (pas par commune), parsing des liens,
    # filtrage cote Python sur (commune | mot-cle ENR). Pas de dependance
    # SearXNG, donc pas de quota a craindre.
    #
    # Lazy refresh : pour les prefectures dont hubs_discovered_at est NULL ou
    # > HUB_TTL_DAYS, on relance discover_hubs_for_domain() AVANT le crawl
    # (cout : 30-90s, paye une fois par TTL). Toutes les autres avancent
    # immediatement avec les hubs deja en base.
    crawl_sources = [s for s in sources
                     if s.get("discovery_mode") == "crawl_index"]
    if crawl_sources:
        enr_keywords = _enr_keywords_for_type(enr_type, enr_label)
        logger.info("  crawl_index : {} sources a fetcher".format(len(crawl_sources)))
        start = time.time()
        for s in crawl_sources:
            try:
                # Refresh lazy si stale ou pas encore decouvert
                _ensure_hubs_fresh(s)
                if not s.get("index_urls"):
                    logger.info("    {} : aucun hub disponible, skip"
                                .format(s["domain"]))
                    continue
                hits = _crawl_index_task(s, communes_all, enr_keywords)
                collected.extend(hits)
                logger.info("    {} : {} hits".format(s["domain"], len(hits)))
            except Exception:
                logger.exception("Echec crawl_index pour {}".format(s["domain"]))
        elapsed = time.time() - start
        logger.info("  crawl_index : termine en {:.1f}s".format(elapsed))

    # --- 3. Sources externes en mode searxng_site -----------------------------
    # On exclut :
    #  - is_internal=true (deja traitees en phase 1)
    #  - domain='*' (free_search, traite en phase 4)
    #  - discovery_mode='crawl_index' (deja traite en phase 2)
    external_sources = [s for s in sources
                        if not s.get("is_internal")
                        and s.get("domain") != "*"
                        and s.get("discovery_mode") != "crawl_index"]
    tasks = [(s, c) for s in external_sources for c in communes_for_search]

    if tasks:
        logger.info("  SearXNG site: {} requetes (concurrency={}, "
                    "{} communes x {} sources)".format(
            len(tasks), SEARXNG_CONCURRENCY,
            len(communes_for_search), len(external_sources)
        ))
        start = time.time()
        with ThreadPoolExecutor(max_workers=SEARXNG_CONCURRENCY) as pool:
            futures = {
                pool.submit(_searxng_task, s, c, enr_label): (s, c)
                for s, c in tasks
            }
            for fut in as_completed(futures):
                try:
                    collected.extend(fut.result())
                except Exception:
                    s, c = futures[fut]
                    logger.exception("Echec tache searxng {}/{}".format(
                        s["domain"], c["nom"]))
        elapsed = time.time() - start
        logger.info("  SearXNG site: {} requetes terminees en {:.1f}s".format(
            len(tasks), elapsed
        ))

    # --- 4. Recherche libre : 1 requete SearXNG SANS site: par commune --------
    # Permet de decouvrir des URLs hors du registre de sources (sites mairie,
    # presse locale non listee, prefectures nouvellement trouvees, etc.).
    # Les URLs remontees sont attribuees a la pseudo-source '*' (free_search).
    free_source = next((s for s in sources if s.get("domain") == "*"), None)
    if free_source:
        free_tasks = list(communes_for_search)
        logger.info("  SearXNG libre : {} requetes (1 par commune)".format(
            len(free_tasks)
        ))
        start = time.time()
        with ThreadPoolExecutor(max_workers=SEARXNG_CONCURRENCY) as pool:
            futures = {
                pool.submit(_searxng_free_task, free_source, c, enr_label): c
                for c in free_tasks
            }
            for fut in as_completed(futures):
                try:
                    collected.extend(fut.result())
                except Exception:
                    c = futures[fut]
                    logger.exception("Echec tache searxng libre pour {}".format(
                        c["nom"]))
        elapsed = time.time() - start
        logger.info("  SearXNG libre : {} requetes terminees en {:.1f}s".format(
            len(free_tasks), elapsed
        ))

    # --- 4. Dedup par URL (garde la premiere occurrence) -----------------------
    # Ordre de priorite : sources internal > site: > free_search
    # (grace a l ordre d insertion dans `collected`).
    seen = set()
    unique = []
    for c in collected:
        if c["url"] not in seen:
            seen.add(c["url"])
            unique.append(c)

    return unique

# ==============================================================================
#  Traitement d un job
# ==============================================================================

def process_job(r, job_id: str) -> None:
    logger.info("=== Job {} ===".format(job_id))

    job = _load_job(r, job_id)
    if job is None:
        logger.error("Job {} introuvable dans Redis, ignore".format(job_id))
        return

    # Passage en processing
    started    = _now_iso()
    t0         = time.monotonic()   # pour mesurer la duree reelle du traitement
    _update_job(r, job_id,
        status="processing",
        started_at=started,
        progress={"step": "consulting_registry", "sources_found": 0},
    )

    commune   = job["commune"]
    dept_code = job["dept_code"]
    enr_type  = job["enr_type"]
    radius_km = job.get("radius_km", 10)
    region    = region_of(dept_code)

    if region is None:
        logger.warning("Region inconnue pour dept_code={} -- seules les sources nationales seront considerees".format(dept_code))
    logger.info("Traitement : {} (dept={}, region={}) type={} radius={}km".format(
        commune, dept_code, region or "?", enr_type, radius_km
    ))

    try:
        # --- Etape 1 : consultation du registre de sources -------------------
        sources = get_candidate_sources(dept_code, enr_type)
        enr_label = get_enr_label(enr_type)

        logger.info("  {} sources candidates (label='{}')".format(len(sources), enr_label))
        for s in sources[:3]:
            logger.info("    {:>5.2f}  {:<35}  ({})".format(
                s["final_score"], s["domain"], s["niveau"]
            ))
        if len(sources) > 3:
            logger.info("    ... et {} autres".format(len(sources) - 3))

        # --- Etape 2 : communes cibles dans le rayon -------------------------
        _update_job(r, job_id,
            progress={"step": "resolving_communes", "sources_found": len(sources)},
        )
        communes = get_target_communes(commune, dept_code, radius_km)

        if not communes:
            logger.warning("Commune '{}' (dept {}) introuvable dans sig.communes -- "
                           "fallback sur la commune seule".format(commune, dept_code))
            # Fallback : on cherche au moins sur la commune telle qu'indiquee
            communes = [{
                "insee_com": None, "nom": commune, "population": None,
                "distance_m": 0.0, "is_origin": True,
            }]

        logger.info("  {} communes dans un rayon de {} km".format(
            len(communes), radius_km
        ))
        # Liste tronquee pour SearXNG (les N plus proches, limite charge moteurs)
        communes_for_search = communes
        if MAX_COMMUNES_PER_JOB > 0 and len(communes) > MAX_COMMUNES_PER_JOB:
            communes_for_search = communes[:MAX_COMMUNES_PER_JOB]
            logger.info("  -> SearXNG limite aux {} plus proches (MAX_COMMUNES_PER_JOB)".format(
                MAX_COMMUNES_PER_JOB
            ))
        for c in communes[:5]:
            logger.info("    {:>6.0f} m  {}".format(c["distance_m"], c["nom"]))
        if len(communes) > 5:
            logger.info("    ... et {} autres".format(len(communes) - 5))

        # --- Etape 3 : recherche web via SearXNG -----------------------------
        _update_job(r, job_id,
            progress={
                "step":            "searching_web",
                "sources_found":   len(sources),
                "communes_target": len(communes),
            },
        )
        urls = collect_urls_for_sources(
            sources=sources,
            communes_all=communes,
            communes_for_search=communes_for_search,
            enr_type=enr_type,
            enr_label=enr_label,
        )

        # Statistiques par methode de collecte
        by_method = {"internal": 0, "crawl_index": 0, "searxng": 0, "free_search": 0}
        for u in urls:
            by_method[u["method"]] = by_method.get(u["method"], 0) + 1

        logger.info("  {} URLs collectees (internal={}, crawl_index={}, "
                    "searxng={}, free={})".format(
            len(urls), by_method["internal"], by_method["crawl_index"],
            by_method["searxng"], by_method["free_search"]
        ))

        # --- Etape 4a : fetch des contenus HTML/PDF --------------------------
        _update_job(r, job_id,
            progress={
                "step":            "fetching_content",
                "sources_found":   len(sources),
                "communes_target": len(communes),
                "urls_found":      len(urls),
            },
        )
        unique_urls = [u["url"] for u in urls]
        fetched = fetch_urls_parallel(unique_urls)
        fetch_stats = fetched["stats"]
        fetched_by_url = fetched["results"]

        # Enrichir chaque URL avec ses metadonnees de fetch (sans le texte complet
        # pour ne pas gonfler le JSON ; le texte reste accessible via url_cache)
        for u in urls:
            f = fetched_by_url.get(u["url"])
            if f is None:
                u["fetch"] = {"method": "skipped", "reason": "internal"}
            else:
                u["fetch"] = {
                    "method":         f.get("fetch_method"),
                    "http_status":    f.get("http_status"),
                    "content_type":   f.get("content_type"),
                    "text_length":    f.get("text_length"),
                    "fetch_duration": round(f.get("fetch_duration") or 0.0, 2),
                    "from_cache":     f.get("from_cache", False),
                    "error":          f.get("error"),
                }

        # --- Etape 4b-1 : pre-extraction regex des candidats projets ---------
        _update_job(r, job_id,
            progress={
                "step":            "extracting_candidates",
                "sources_found":   len(sources),
                "communes_target": len(communes),
                "urls_found":      len(urls),
                "urls_fetched":    fetch_stats["fetched"] + fetch_stats["cached"],
            },
        )
        extract_stats = extract_all_candidates(
            job_id=job_id,
            urls=urls,
            fetched_by_url=fetched_by_url,
            communes=communes,
            enr_type=enr_type,
        )

        # --- Resultat final ---------------------------------------------------
        result = {
            "commune":          commune,
            "dept_code":        dept_code,
            "enr_type":         enr_type,
            "enr_label":        enr_label,
            "radius_km":        radius_km,
            "sources":          sources,
            "total_sources":    len(sources),
            "target_communes":  communes,
            "total_communes":   len(communes),
            "urls":             urls,
            "total_urls":       len(urls),
            "urls_by_method":   by_method,
            "fetch_stats":      fetch_stats,
            "extract_stats":    extract_stats,
            "note":             "Etape 4b-1 -- URLs fetchees + pre-extraction regex, pas encore de LLM",
        }

        _update_job(r, job_id,
            status="done",
            finished_at=_now_iso(),
            result=result,
            progress={
                "step":            "done",
                "sources_found":   len(sources),
                "communes_target": len(communes),
                "urls_found":      len(urls),
                "urls_fetched":    fetch_stats["fetched"] + fetch_stats["cached"],
                "candidates":      extract_stats["extracted_direct"] + extract_stats["internal"],
                "needs_llm":       extract_stats["needs_llm"],
            },
        )
        logger.info("Job {} termine en {:.1f}s : {} sources x {} communes -> "
                    "{} URLs -> {} fetch OK -> {} candidats directs, "
                    "{} a traiter par LLM".format(
            job_id, time.monotonic() - t0, len(sources), len(communes),
            len(urls),
            fetch_stats["html"] + fetch_stats["pdf"],
            extract_stats["extracted_direct"] + extract_stats["internal"],
            extract_stats["needs_llm"],
        ))

    except Exception as e:
        logger.exception("Erreur lors du traitement du job {} (apres {:.1f}s)".format(
            job_id, time.monotonic() - t0
        ))
        _update_job(r, job_id,
            status="error",
            finished_at=_now_iso(),
            error=str(e)[:500],
        )

# ==============================================================================
#  Boucle principale
# ==============================================================================

def main():
    logger.info("NEWS Scraper agent demarre")
    logger.info("  DB_HOST    = {}".format(DB_HOST))
    logger.info("  OLLAMA_HOST= {}".format(os.getenv("OLLAMA_HOST")))
    logger.info("  REDIS_URL  = {}".format(REDIS_URL))

    # Attente que les services dependants soient prets (evite boucle de crash
    # au tout premier demarrage si redis/postgres sont plus lents).
    for attempt in range(10):
        try:
            r = get_redis()
            r.ping()
            conn = get_db()
            conn.close()
            logger.info("Redis + PostgreSQL accessibles")
            break
        except Exception as e:
            logger.warning("Dependance indisponible (tentative {}/10) : {}".format(
                attempt + 1, e))
            time.sleep(3)
    else:
        logger.error("Impossible de joindre Redis ou PostgreSQL, arret")
        return

    logger.info("En attente de jobs sur '{}' (timeout BRPOP {}s)".format(
        QUEUE_KEY, BRPOP_TIMEOUT_SEC))

    r = get_redis()

    while not _shutdown:
        try:
            # BRPOP bloque jusqu a BRPOP_TIMEOUT_SEC ; permet de reagir a SIGTERM
            pop = r.brpop(QUEUE_KEY, timeout=BRPOP_TIMEOUT_SEC)
            if pop is None:
                continue  # timeout normal, on reboucle
            _, job_id = pop
            process_job(r, job_id)
        except redis.ConnectionError as e:
            logger.error("Perte connexion Redis : {} -- reconnexion dans 5s".format(e))
            time.sleep(5)
            r = get_redis()
        except Exception:
            logger.exception("Erreur inattendue dans la boucle principale")
            time.sleep(2)

    logger.info("Agent arrete proprement")

if __name__ == "__main__":
    main()
'@
}