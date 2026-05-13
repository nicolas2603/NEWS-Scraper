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
NEWS Scraper -- Agent de recherche ENR

Pipeline :
  Phase 1  : mrae.avis        SQL direct                     -> candidats internal
  Phase 2  : crawl_index      96 prefectures DSFR            -> candidats crawl
  Phase 3  : searxng_site     top N sources x 5 communes     -> candidats searxng
  Phase 4a : fetch            HTML/PDF, cache TTL 30j
  Phase 4b : extraction regex puissance, surface, porteur, date, statut, resume
  Phase 5  : filtre ENR       photovoltaique / agrivoltaique / eolien
  Phase 6  : consolidation    N sources -> 1 projet
  Phase 7  : LLM optionnel    resume enrichi post-consolidation
  Phase 8  : export CSV       separateur ; , encodage utf-8-sig
"""

# ==============================================================================
#  1. IMPORTS
# ==============================================================================

import os
import json
import re
import signal
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from threading import Lock, Semaphore
from typing import List, Optional
from urllib.parse import urlparse

import httpx
import redis
import psycopg2
from psycopg2.extras import RealDictCursor
from loguru import logger

# ==============================================================================
#  2. CONFIGURATION
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
BRPOP_TIMEOUT_SEC = 5

# --- SearXNG ------------------------------------------------------------------
SEARXNG_URL             = os.getenv("SEARXNG_URL", "http://news_searxng:8080")
SEARXNG_TIMEOUT_SEC     = 15
SEARXNG_MAX_RESULTS     = 5
SEARXNG_CONCURRENCY     = int(os.getenv("SEARXNG_CONCURRENCY", "1"))
SEARXNG_QUERY_DELAY_SEC = float(os.getenv("SEARXNG_QUERY_DELAY_SEC", "3"))
SEARXNG_CACHE_TTL_HOURS = int(os.getenv("SEARXNG_CACHE_TTL_HOURS", "24"))

# Phase 3 SearXNG : limiter sources et communes pour rester < 10 min
SEARXNG_MAX_SOURCES  = int(os.getenv("SEARXNG_MAX_SOURCES", "20"))
SEARXNG_MAX_COMMUNES = int(os.getenv("SEARXNG_MAX_COMMUNES", "5"))

# --- Fetch & cache -----------------------------------------------------------
TIKA_URL             = os.getenv("TIKA_URL", "http://mrae_tika:9998")
FETCH_CONCURRENCY    = int(os.getenv("FETCH_CONCURRENCY", "10"))
FETCH_PER_DOMAIN_MAX = int(os.getenv("FETCH_PER_DOMAIN_MAX", "2"))
FETCH_TIMEOUT_SEC    = int(os.getenv("FETCH_TIMEOUT_SEC", "15"))
FETCH_TEXT_MAX_CHARS = int(os.getenv("FETCH_TEXT_MAX_CHARS", "50000"))
URL_CACHE_TTL_DAYS   = int(os.getenv("URL_CACHE_TTL_DAYS", "30"))

MAX_COMMUNES_PER_JOB = int(os.getenv("MAX_COMMUNES_PER_JOB", "0"))

# --- LLM normalisation des noms de projets (mrae_ollama partage) -------------
OLLAMA_HOST          = os.getenv("OLLAMA_HOST",   "http://mrae_ollama:11434")
OLLAMA_MODEL         = os.getenv("OLLAMA_MODEL",  "qwen2.5:7b")
OLLAMA_TIMEOUT_NAMES = int(os.getenv("OLLAMA_TIMEOUT_NAMES", "600"))
OLLAMA_ENABLED    = os.getenv("OLLAMA_ENABLED", "false").lower() == "true"

_UA_CHROME = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# ==============================================================================
#  3. CONSTANTES METIER
#     Types ENR cibles, mots-cles, patterns statut, expressions regulieres.
# ==============================================================================

# --- Labels et types ENR ------------------------------------------------------
ENR_LABELS = {
    "photovoltaique": "photovoltaique",
    "agrivoltaique":  "agrivoltaique",
    "eolien":         "eolien",
}

ENR_TYPES_TARGET = {"photovoltaique", "agrivoltaique", "eolien"}

ENR_KEYWORDS = {
    "photovoltaique": ["photovoltaique","photovoltaiques","centrale solaire","parc solaire",
                       "centrale pv","centrale photovoltaique"],
    "agrivoltaique":  ["agrivoltaique","agrivoltaiques","agrivoltaisme","agri-pv","agripv"],
    "eolien":         ["eolien","eolienne","eoliennes","parc eolien","turbine eolienne"],
}

ENR_KEYWORDS_ALL    = [k for kws in ENR_KEYWORDS.values() for k in kws]
ENR_KEYWORDS_TARGET = ENR_KEYWORDS_ALL

# --- Signaux projet dans le texte (pour le score de pertinence) ---------------
PROJECT_SIGNAL_KEYWORDS = [
    "projet","projets","enquete publique","permis de construire",
    "autorisation environnementale","implantation","installation","construction",
    "mise en service","developpement","raccordement","instruction","autorisation",
    "hectares","ha "," mw"," mwc","exploitation",
]

# --- Statuts proceduraux (detectes par mots-cles dans le texte) ---------------
_STATUT_PATTERNS = [
    ("enquete_publique", ["enquête publique", "enquete publique",
                          "commissaire enquêteur", "commissaire-enquêteur"]),
    ("autorise",         ["arrêté préfectoral", "autorisation accordée",
                          "autorisé", "permis de construire", "avis favorable"]),
    ("refuse",           ["refusé", "rejeté", "avis défavorable"]),
    ("instruction",      ["en cours d'instruction", "dossier déposé",
                          "recevabilité", "dossier de demande"]),
    ("en_service",       ["mise en service", "en service", "raccordé"]),
]

# --- Expressions regulieres ---------------------------------------------------
_RE_POWER     = re.compile(r"(\d{1,4}(?:[\.,]\d{1,3})?)\s*(mwc?\b|megawatts?\b|m\.w\.c?\.?)", re.I)
_RE_AREA      = re.compile(r"(\d{1,4}(?:[\.,]\d{1,3})?)\s*(ha\b|hectares?\b)", re.I)
_RE_DATE_NUM  = re.compile(r"\b(\d{1,2})[\s/\-\.](\d{1,2})[\s/\-\.](\d{4})\b")
_RE_DATE_TEXT = re.compile(
    r"\b(\d{1,2})\s+(janvier|fevrier|mars|avril|mai|juin|juillet|"
    r"aout|septembre|octobre|novembre|decembre)\s+(\d{4})\b", re.I)
_RE_COMMUNE_TITLE = re.compile(
    r"(?:communes?\s+de\s+|sur\s+(?:la\s+)?commune\s+de\s+"
    r"|territoire\s+de\s+)"
    r"(\w[\w\-]*(?:\s+\w[\w\-]*)*)",
    re.IGNORECASE | re.UNICODE,
)

# ==============================================================================
#  4. MAPPING GEOGRAPHIQUE
#     Departement -> region administrative (pour le scoring des sources).
# ==============================================================================

DEPT_TO_REGION = {
    "001":"Auvergne-Rhone-Alpes","003":"Auvergne-Rhone-Alpes","007":"Auvergne-Rhone-Alpes",
    "015":"Auvergne-Rhone-Alpes","026":"Auvergne-Rhone-Alpes","038":"Auvergne-Rhone-Alpes",
    "042":"Auvergne-Rhone-Alpes","043":"Auvergne-Rhone-Alpes","063":"Auvergne-Rhone-Alpes",
    "069":"Auvergne-Rhone-Alpes","073":"Auvergne-Rhone-Alpes","074":"Auvergne-Rhone-Alpes",
    "021":"Bourgogne-Franche-Comte","025":"Bourgogne-Franche-Comte",
    "039":"Bourgogne-Franche-Comte","058":"Bourgogne-Franche-Comte",
    "070":"Bourgogne-Franche-Comte","071":"Bourgogne-Franche-Comte",
    "089":"Bourgogne-Franche-Comte","090":"Bourgogne-Franche-Comte",
    "022":"Bretagne","029":"Bretagne","035":"Bretagne","056":"Bretagne",
    "018":"Centre-Val de Loire","028":"Centre-Val de Loire","036":"Centre-Val de Loire",
    "037":"Centre-Val de Loire","041":"Centre-Val de Loire","045":"Centre-Val de Loire",
    "02A":"Corse","02B":"Corse",
    "008":"Grand Est","010":"Grand Est","051":"Grand Est","052":"Grand Est",
    "054":"Grand Est","055":"Grand Est","057":"Grand Est","067":"Grand Est",
    "068":"Grand Est","088":"Grand Est",
    "002":"Hauts-de-France","059":"Hauts-de-France","060":"Hauts-de-France",
    "062":"Hauts-de-France","080":"Hauts-de-France",
    "075":"Ile-de-France","077":"Ile-de-France","078":"Ile-de-France",
    "091":"Ile-de-France","092":"Ile-de-France","093":"Ile-de-France",
    "094":"Ile-de-France","095":"Ile-de-France",
    "014":"Normandie","027":"Normandie","050":"Normandie","061":"Normandie","076":"Normandie",
    "016":"Nouvelle-Aquitaine","017":"Nouvelle-Aquitaine","019":"Nouvelle-Aquitaine",
    "023":"Nouvelle-Aquitaine","024":"Nouvelle-Aquitaine","033":"Nouvelle-Aquitaine",
    "040":"Nouvelle-Aquitaine","047":"Nouvelle-Aquitaine","064":"Nouvelle-Aquitaine",
    "079":"Nouvelle-Aquitaine","086":"Nouvelle-Aquitaine","087":"Nouvelle-Aquitaine",
    "009":"Occitanie","011":"Occitanie","012":"Occitanie","030":"Occitanie",
    "031":"Occitanie","032":"Occitanie","034":"Occitanie","046":"Occitanie",
    "048":"Occitanie","065":"Occitanie","066":"Occitanie","081":"Occitanie","082":"Occitanie",
    "044":"Pays de la Loire","049":"Pays de la Loire","053":"Pays de la Loire",
    "072":"Pays de la Loire","085":"Pays de la Loire",
    "004":"Provence-Alpes-Cote d'Azur","005":"Provence-Alpes-Cote d'Azur",
    "006":"Provence-Alpes-Cote d'Azur","013":"Provence-Alpes-Cote d'Azur",
    "083":"Provence-Alpes-Cote d'Azur","084":"Provence-Alpes-Cote d'Azur",
    "971":"Guadeloupe","972":"Martinique","973":"Guyane",
    "974":"La Reunion","976":"Mayotte",
}

def region_of(dept_code: str) -> Optional[str]:
    return DEPT_TO_REGION.get(dept_code)

# ==============================================================================
#  5. HELPERS GENERIQUES
#     Connexions DB/Redis, gestion des jobs, normalisation texte.
# ==============================================================================

# --- Clients ------------------------------------------------------------------

def get_redis():
    return redis.from_url(REDIS_URL, decode_responses=True)

def get_db():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD
    )

# --- Gestion des jobs Redis ---------------------------------------------------

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def _job_key(job_id: str) -> str:
    return "{}{}".format(JOB_KEY_PREFIX, job_id)

def _load_job(r, job_id: str) -> Optional[dict]:
    raw = r.get(_job_key(job_id))
    return json.loads(raw) if raw else None

def _save_job(r, job: dict) -> None:
    r.set(_job_key(job["job_id"]), json.dumps(job, default=str), ex=JOB_TTL_DAYS * 86400)

def _update_job(r, job_id: str, **fields) -> Optional[dict]:
    job = _load_job(r, job_id)
    if job is None:
        logger.warning("Job {} introuvable".format(job_id))
        return None
    job.update(fields)
    job["updated_at"] = _now_iso()
    _save_job(r, job)
    return job

# --- Normalisation texte (utilisee dans tout le pipeline) --------------------

def _normalize(s: str) -> str:
    if not s:
        return ""
    nfd = unicodedata.normalize("NFD", s.lower())
    return "".join(c for c in nfd if unicodedata.category(c) != "Mn")

# ==============================================================================
#  6. PHASES 1-3 : COLLECTE D'URLs
#     Sources, communes, crawl prefectoral, SearXNG.
#     Sortie : liste de dicts {url, method, domain, matched_commune, ...}
# ==============================================================================

# --- 6.1 Sources et labels ENR -----------------------------------------------

def get_candidate_sources(dept_code: str, enr_type: str) -> List[dict]:
    region = region_of(dept_code)
    conn   = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT source_id, domain, name, source_type, signal_type,
                       discovery_mode, index_urls,
                       hubs_discovered_at, niveau, final_score::float AS final_score
                FROM news.get_best_sources(%(enr_type)s, %(region)s, %(dept)s, %(limit)s)
                """,
                {"enr_type": enr_type, "region": region, "dept": dept_code, "limit": 25}
            )
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

def get_enr_label(enr_type: str) -> str:
    return ENR_LABELS.get(enr_type, enr_type)

# --- 6.2 Communes cibles (rayon geographique) --------------------------------

def get_target_communes(commune: str, dept_code: str, radius_km: int) -> List[dict]:
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT insee_com, nom, population, distance_m, is_origin "
                "FROM news.get_communes_in_radius(%s, %s, %s)",
                (commune, dept_code, radius_km),
            )
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

# --- 6.3 Phase 1 : avis MRAE internes ----------------------------------------

def get_internal_avis(communes: List[dict], enr_type: str) -> List[dict]:
    """Phase 1 : avis MRAE directs via SQL (source interne, discovery_mode='internal')."""
    insee_codes = [c["insee_com"] for c in communes if c.get("insee_com")]
    if not insee_codes:
        return []
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT r_avis_id AS avis_id, r_reference_cle AS reference_cle,
                       r_nom_projet AS nom_projet, r_date_avis AS date_avis,
                       r_avis_type AS avis_type, r_maitre_ouvrage AS maitre_ouvrage,
                       r_puissance_mw AS puissance_mw, r_superficie_ha AS superficie_ha,
                       r_location AS location, r_poste_connexion AS poste_connexion,
                       r_resume AS resume, r_pdf_path AS pdf_path,
                       r_matched_commune AS matched_commune
                FROM news.get_internal_avis(%s::text[], %s)
                """,
                (insee_codes, enr_type),
            )
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

# --- 6.4 Phase 3 : moteur SearXNG (cache + recherche) ------------------------

_SEARXNG_LOCK        = threading.Lock()
_SEARXNG_LAST_HIT_AT = [0.0]

def _searxng_cache_lookup(query: str) -> Optional[List[dict]]:
    try:
        conn = get_db()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT results FROM news.searxng_cache "
                "WHERE query=%s AND fetched_at > NOW() - %s::interval",
                (query, "{} hours".format(SEARXNG_CACHE_TTL_HOURS)),
            )
            row = cur.fetchone()
        conn.close()
        return row["results"] if row else None
    except Exception as e:
        logger.warning("SearXNG cache lookup KO: {}".format(e))
        return None

def _searxng_cache_store(query: str, results: List[dict]) -> None:
    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO news.searxng_cache(query,results,n_results,fetched_at) "
                "VALUES(%s,%s::jsonb,%s,NOW()) "
                "ON CONFLICT(query) DO UPDATE SET results=EXCLUDED.results, "
                "n_results=EXCLUDED.n_results, fetched_at=NOW()",
                (query, json.dumps(results), len(results)),
            )
            conn.commit()
        conn.close()
    except Exception as e:
        logger.warning("SearXNG cache store KO: {}".format(e))

def searxng_search(query: str, max_results: int = SEARXNG_MAX_RESULTS) -> List[dict]:
    cached = _searxng_cache_lookup(query)
    if cached is not None:
        return [r for r in cached if r.get("url")][:max_results]

    with _SEARXNG_LOCK:
        elapsed = time.time() - _SEARXNG_LAST_HIT_AT[0]
        if elapsed < SEARXNG_QUERY_DELAY_SEC:
            time.sleep(SEARXNG_QUERY_DELAY_SEC - elapsed)
        try:
            resp = httpx.get("{}/search".format(SEARXNG_URL),
                             params={"q": query, "format": "json", "language": "fr"},
                             timeout=SEARXNG_TIMEOUT_SEC)
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            logger.warning("SearXNG echec '{}': {}".format(query, e))
            _SEARXNG_LAST_HIT_AT[0] = time.time()
            return []
        _SEARXNG_LAST_HIT_AT[0] = time.time()

    raw = [{"url": r.get("url",""), "title": r.get("title",""), "snippet": r.get("content","")}
           for r in data.get("results", []) if r.get("url")]
    _searxng_cache_store(query, raw)
    return raw[:max_results]

# --- 6.5 Phase 2 : crawl index DSFR des hubs prefectoraux --------------------

_INDEX_CACHE         = {}
_INDEX_CACHE_TTL_SEC = 4 * 3600
_CRAWL_MAX_PAGES     = 10
_CRAWL_PAGE_STEP     = 10

def _fetch_one_index_page(page_url: str, dsfr_only: bool = False) -> tuple:
    try:
        resp = httpx.get(page_url, timeout=15.0, headers={"User-Agent": _UA_CHROME},
                         follow_redirects=True)
        resp.raise_for_status()
    except Exception as e:
        logger.warning("Crawl index KO {}: {}".format(page_url, e))
        return ([], None, False)

    from bs4 import BeautifulSoup
    from urllib.parse import urljoin
    try:
        soup = BeautifulSoup(resp.text, "lxml")
    except Exception:
        return ([], None, False)

    base_netloc = urlparse(page_url).netloc.lower()
    hits = []
    seen = set()

    # Etage 1 : DSFR fr-card__link
    dsfr = soup.select("a.fr-card__link[href]")
    if dsfr:
        for a in dsfr:
            href = (a.get("href") or "").strip()
            if not href or href.startswith(("#", "javascript:")):
                continue
            full = urljoin(page_url, href)
            try:
                nl = urlparse(full).netloc.lower()
            except Exception:
                continue
            if not (nl == base_netloc or nl.endswith("." + base_netloc.lstrip("www."))):
                continue
            text = a.get_text(strip=True)
            if text and len(text) >= 10 and full not in seen:
                card    = a.find_parent(class_=lambda c: c and "fr-card" in c)
                det_el  = card.select_one(".fr-card__detail") if card else None
                pub_date = det_el.get_text(strip=True) if det_el else ""

                seen.add(full)
                hits.append({"url": full, "title": text[:300], "snippet": "", "pub_date": pub_date})
        if hits:
            return (hits, soup, True)

    if dsfr_only:
        return ([], soup, False)

    # Etage 2 : fallback generique
    stop = {"accueil","contact","mentions legales","plan du site","rss","facebook",
            "twitter","linkedin","youtube","imprimer","partager","telecharger",
            "haut de page","demarches","actualites","agenda","newsletter",
            "se connecter","deconnexion","inscription","abonnement",
            "outils d accessibilite","version mobile","english","search",
            "recherche","tout le site","voir tout","voir plus","publications",
            "annonces","etat civil"}
    for a in soup.select("a[href]"):
        href = (a.get("href") or "").strip()
        if not href or href.startswith(("#","javascript:","mailto:","tel:")):
            continue
        full = urljoin(page_url, href)
        try:
            nl = urlparse(full).netloc.lower()
        except Exception:
            continue
        if not (nl == base_netloc or nl.endswith("." + base_netloc.lstrip("www."))):
            continue
        text = a.get_text(strip=True)
        if not text or len(text) < 10:
            continue
        tn = _normalize(text)
        if tn in stop or tn.isdigit():
            continue
        if tn in {"page suivante","page precedente","suivant","precedent",
                  "premiere page","derniere page"}:
            continue
        if full not in seen:
            seen.add(full)
            hits.append({"url": full, "title": text[:300], "snippet": ""})
    return (hits, soup, False)

def _crawl_index_page(index_url: str) -> List[dict]:
    now = time.time()
    cached = _INDEX_CACHE.get(index_url)
    if cached and now - cached[0] < _INDEX_CACHE_TTL_SEC:
        return cached[1]

    hits, soup, used_dsfr = _fetch_one_index_page(index_url)
    all_hits  = list(hits)
    seen_urls = {h["url"] for h in all_hits}

    has_pag = soup is not None and any(
        "(offset)/" in (a.get("href") or "") for a in soup.select("a[href]"))

    if has_pag:
        base = index_url.rstrip("/")
        for n in range(1, _CRAWL_MAX_PAGES):
            ph, _, _ = _fetch_one_index_page(
                "{}/(offset)/{}".format(base, n * _CRAWL_PAGE_STEP),
                dsfr_only=used_dsfr)
            new = [h for h in ph if h["url"] not in seen_urls]
            if not new:
                break
            all_hits.extend(new)
            seen_urls.update(h["url"] for h in new)

    _INDEX_CACHE[index_url] = (now, all_hits)
    return all_hits

def _crawl_index_task(source: dict, communes: List[dict], enr_keywords: List[str]) -> List[dict]:
    """Phase 2 : scraping direct des hubs prefectoraux DSFR (discovery_mode='crawl_index')."""
    index_urls = source.get("index_urls") or []
    if not index_urls:
        logger.warning("Source {} crawl_index sans index_urls".format(source["domain"]))
        return []

    raw_hits  = []
    seen_urls = set()
    for url in index_urls:
        for h in _crawl_index_page(url):
            if h["url"] not in seen_urls:
                seen_urls.add(h["url"])
                raw_hits.append({**h, "from_hub": url})

    if not raw_hits:
        return []

    communes_norm     = [(c["nom"], _normalize(c["nom"])) for c in communes
                         if c.get("nom") and len(c["nom"]) >= 4]
    communes_norm_set = {norm for _, norm in communes_norm}
    kw_norm           = [_normalize(k) for k in enr_keywords if k]
    source_base = {"source_id": source["source_id"], "domain": source["domain"],
                   "niveau": source["niveau"], "source_type": source.get("source_type")}
    out = []
    for h in raw_hits:
        tn = _normalize(h["title"])
        # Tirets -> espaces pour matcher "la-celle" -> "la celle"
        un = _normalize(h["url"]).replace("-", " ")
        mc = next((nom for nom, norm in communes_norm if norm in tn or norm in un), None)
        if not mc and not any(k in tn for k in kw_norm):
            continue
        # Commune depuis le titre si mc absent, validee dans le rayon
        commune_titre = _extract_commune_from_title(h["title"])
        if commune_titre and _normalize(commune_titre) not in communes_norm_set:
            commune_titre = None
        commune_final = mc or commune_titre
        # Rejeter si aucune commune du rayon confirmee
        if not commune_final:
            continue
        out.append({**source_base, "method": "crawl_index",
                    "url":             h["url"],
                    "title":           h["title"],
                    "snippet":         "",
                    "pub_date":        h.get("pub_date", ""),
                    "hub_statut":      _statut_from_hub_url(h.get("from_hub", "")),
                    "matched_commune": commune_final})
    return out

# --- 6.6 Phase 3 : tache SearXNG par source et commune -----------------------

def _searxng_task(source: dict, commune: dict, enr_label: str) -> List[dict]:
    """Phase 3 : recherche SearXNG site:<domain> "commune" enr_label."""
    sb    = {"source_id": source["source_id"], "domain": source["domain"],
             "niveau": source["niveau"], "source_type": source.get("source_type")}
    query = 'site:{} "{}" {}'.format(source["domain"], commune["nom"], enr_label)
    return [{**sb, "method": "searxng", "url": h["url"], "title": h["title"],
             "snippet": h["snippet"], "matched_commune": commune["nom"]}
            for h in searxng_search(query)]

# --- 6.7 Orchestration collecte (Phases 1 + 2 + 3) ---------------------------

def _enr_keywords_for_type(enr_type: str, enr_label: str) -> List[str]:
    base = list(ENR_KEYWORDS.get(enr_type, []))
    if enr_label:
        base.append(enr_label)
    return base

def collect_urls_for_sources(
    sources: List[dict], communes_all: List[dict], communes_for_search: List[dict],
    enr_type: str, enr_label: str,
) -> List[dict]:
    collected = []

    # Phase 1 : internal
    for s in [s for s in sources if s.get("discovery_mode") == "internal"]:
        avis_list = get_internal_avis(communes_all, enr_type)
        logger.info("  internal '{}' : {} avis".format(s["domain"], len(avis_list)))
        for a in avis_list:
            collected.append({
                "source_id":s["source_id"],"domain":s["domain"],"niveau":s["niveau"],
                "source_type":s.get("source_type"),
                "method":"internal",
                "url":"internal://{}/{}".format(s["domain"], a["avis_id"]),
                "title":a["nom_projet"] or "(sans titre)",
                "snippet":(a["resume"] or "")[:500],
                "matched_commune":a["matched_commune"],
                "extra":{
                    "avis_id":a["avis_id"],"reference_cle":a["reference_cle"],
                    "date_avis":a["date_avis"].isoformat() if a["date_avis"] else None,
                    "avis_type":a["avis_type"],"maitre_ouvrage":a["maitre_ouvrage"],
                    "puissance_mw":float(a["puissance_mw"]) if a["puissance_mw"] is not None else None,
                    "superficie_ha":float(a["superficie_ha"]) if a["superficie_ha"] is not None else None,
                    "location":a["location"],"poste_connexion":a["poste_connexion"],
                    "pdf_path":a["pdf_path"],
                },
            })

    # Phase 2 : crawl_index
    crawl_sources = [s for s in sources if s.get("discovery_mode") == "crawl_index"]
    if crawl_sources:
        kws   = _enr_keywords_for_type(enr_type, enr_label)
        logger.info("  crawl_index : {} sources".format(len(crawl_sources)))
        start = time.time()
        for s in crawl_sources:
            try:
                if not s.get("index_urls"):
                    logger.info("    {} : aucun hub, skip".format(s["domain"]))
                    continue
                hits = _crawl_index_task(s, communes_all, kws)
                collected.extend(hits)
                logger.info("    {} : {} hits".format(s["domain"], len(hits)))
            except Exception:
                logger.exception("Echec crawl_index {}".format(s["domain"]))
        logger.info("  crawl_index : {:.1f}s".format(time.time()-start))

    # Phase 3 : searxng_site
    # Top SEARXNG_MAX_SOURCES sources par score + SEARXNG_MAX_COMMUNES communes les plus proches
    ext = [s for s in sources
           if s.get("discovery_mode") not in ("internal", "crawl_index")]
    ext = sorted(ext, key=lambda s: s.get("final_score", 0), reverse=True)[:SEARXNG_MAX_SOURCES]
    communes_searxng = communes_for_search[:SEARXNG_MAX_COMMUNES]
    tasks = [(s, c) for s in ext for c in communes_searxng]
    if tasks:
        logger.info("  SearXNG : {} req ({} sources x {} communes)".format(
            len(tasks), len(ext), len(communes_searxng)))
        start = time.time()
        with ThreadPoolExecutor(max_workers=SEARXNG_CONCURRENCY) as pool:
            futures = {pool.submit(_searxng_task, s, c, enr_label):(s,c) for s,c in tasks}
            for fut in as_completed(futures):
                try:
                    collected.extend(fut.result())
                except Exception:
                    s,c = futures[fut]
                    logger.exception("Echec searxng {}/{}".format(s["domain"],c["nom"]))
        logger.info("  SearXNG : {:.1f}s".format(time.time()-start))

    # Dedup
    seen   = set()
    unique = []
    for c in collected:
        if c["url"] not in seen:
            seen.add(c["url"])
            unique.append(c)
    return unique

# ==============================================================================
#  7. PHASE 4a : FETCH CONTENU
#     Telechargement HTTP des URLs collectees, avec cache TTL 30j.
#     HTML extrait via trafilatura, PDF via Apache Tika.
# ==============================================================================

_domain_semaphores_lock = Lock()
_domain_semaphores: dict = {}

def _get_domain_semaphore(url: str) -> Semaphore:
    host = urlparse(url).netloc.lower()
    with _domain_semaphores_lock:
        if host not in _domain_semaphores:
            _domain_semaphores[host] = Semaphore(FETCH_PER_DOMAIN_MAX)
    return _domain_semaphores[host]

def _url_cache_get(url: str) -> Optional[dict]:
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT url,http_status,content_type,fetch_method,text,text_length,"
                "fetch_duration,error,fetched_at FROM news.url_cache "
                "WHERE url=%s AND fetched_at > NOW() - (%s || ' days')::interval",
                (url, URL_CACHE_TTL_DAYS),
            )
            row = cur.fetchone()
            return dict(row) if row else None
    finally:
        conn.close()

def _url_cache_put(entry: dict) -> None:
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO news.url_cache(url,http_status,content_type,fetch_method,"
                "text,text_length,fetch_duration,error,fetched_at) "
                "VALUES(%(url)s,%(http_status)s,%(content_type)s,%(fetch_method)s,"
                "%(text)s,%(text_length)s,%(fetch_duration)s,%(error)s,NOW()) "
                "ON CONFLICT(url) DO UPDATE SET "
                "http_status=EXCLUDED.http_status,content_type=EXCLUDED.content_type,"
                "fetch_method=EXCLUDED.fetch_method,text=EXCLUDED.text,"
                "text_length=EXCLUDED.text_length,fetch_duration=EXCLUDED.fetch_duration,"
                "error=EXCLUDED.error,fetched_at=EXCLUDED.fetched_at",
                entry,
            )
            conn.commit()
    finally:
        conn.close()

def _extract_html_metadata(html: str) -> str:
    from bs4 import BeautifulSoup
    try:
        soup = BeautifulSoup(html, "lxml")
    except Exception:
        return ""
    parts = []
    if soup.title and soup.title.string:
        parts.append(soup.title.string.strip())
    for sel in [{"name": "description"}, {"property": "og:description"}]:
        meta = soup.find("meta", attrs=sel)
        if meta and meta.get("content"):
            parts.append(meta["content"].strip())
            break
    h1 = soup.find("h1")
    if h1:
        t = h1.get_text(strip=True)
        if t:
            parts.append(t)
    container = soup.find("article") or soup.find("main") or soup.body
    if container:
        for p in container.find_all("p"):
            t = p.get_text(strip=True)
            if len(t) >= 80:
                parts.append(t)
                break
    return "\n".join(dict.fromkeys(parts))

def _extract_html(html: str, url: str) -> str:
    import trafilatura
    main = trafilatura.extract(html, url=url, include_comments=False,
                               include_tables=False, favor_precision=False) or ""
    if len(main) < 500:
        fb = _extract_html_metadata(html)
        if fb and len(fb) > len(main):
            main = fb
    return main[:FETCH_TEXT_MAX_CHARS]

def _extract_pdf_via_tika(pdf_bytes: bytes) -> str:
    r = httpx.put(TIKA_URL + "/tika", content=pdf_bytes,
                  headers={"Accept": "text/plain"}, timeout=60.0)
    r.raise_for_status()
    return r.text[:FETCH_TEXT_MAX_CHARS]

def fetch_url(url: str) -> dict:
    cached = _url_cache_get(url)
    if cached is not None:
        cached["from_cache"] = True
        return cached

    with _get_domain_semaphore(url):
        entry = {"url": url, "http_status": None, "content_type": None,
                 "fetch_method": "error", "text": None, "text_length": 0,
                 "fetch_duration": 0.0, "error": None}
        start = time.time()
        try:
            with httpx.Client(
                follow_redirects=True, timeout=FETCH_TIMEOUT_SEC,
                headers={"User-Agent": _UA_CHROME,
                         "Accept": "text/html,application/pdf;q=0.9,*/*;q=0.8",
                         "Accept-Language": "fr-FR,fr;q=0.9,en;q=0.8"},
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
                entry["error"] = "content-type: {}".format(entry["content_type"])
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

    if entry["fetch_method"] in ("html","pdf","skipped") or entry["http_status"] == 404:
        try:
            _url_cache_put(entry)
        except Exception:
            logger.exception("Echec url_cache {}".format(url))

    entry["from_cache"] = False
    return entry

def fetch_urls_parallel(urls: List[str]) -> dict:
    """Phase 4a : fetch HTML/PDF en parallele avec cache TTL 30j."""
    targets = [u for u in urls if not u.startswith("internal://")]
    results: dict = {}
    stats = {"fetched": 0,"cached": 0,"html": 0,"pdf": 0,
             "skipped": 0,"errors": 0,"total": len(targets)}
    if not targets:
        return {"results": results, "stats": stats}

    logger.info("  Fetch : {} URLs (concurrency={})".format(len(targets), FETCH_CONCURRENCY))
    start = time.time()
    with ThreadPoolExecutor(max_workers=FETCH_CONCURRENCY) as pool:
        futures = {pool.submit(fetch_url, u): u for u in targets}
        for fut in as_completed(futures):
            u = futures[fut]
            try:
                e = fut.result()
                results[u] = e
                stats["cached" if e.get("from_cache") else "fetched"] += 1
                m = e.get("fetch_method")
                if m == "html":      stats["html"]    += 1
                elif m == "pdf":     stats["pdf"]     += 1
                elif m == "skipped": stats["skipped"] += 1
                elif m == "error":   stats["errors"]  += 1
            except Exception:
                logger.exception("Echec fetch {}".format(u))
                stats["errors"] += 1
    logger.info("  Fetch : {} en {:.1f}s (cache={},fetched={},html={},pdf={},skip={},err={})".format(
        len(targets), time.time()-start, stats["cached"], stats["fetched"],
        stats["html"], stats["pdf"], stats["skipped"], stats["errors"]))
    return {"results": results, "stats": stats}

# ==============================================================================
#  8. PHASE 4b : EXTRACTION REGEX
#     Extraction des champs projet depuis le texte brut :
#     puissance, surface, porteur, date, statut, commune, resume.
# ==============================================================================

# --- 8.1 Developpeurs ENR (charges depuis news.sources au demarrage) ---------

_DEVELOPER_NAMES: List[tuple] = []   # [(canonical_name, domain_hint), ...]

def _load_developer_names() -> None:
    """Charge les noms de developpeurs depuis news.sources."""
    global _DEVELOPER_NAMES
    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT name, domain FROM news.sources "
                "WHERE source_type = 'developer' AND is_active = true "
                "ORDER BY name"
            )
            _DEVELOPER_NAMES = [(row[0], row[1].split(".")[0]) for row in cur.fetchall()]
        conn.close()
    except Exception as e:
        logger.warning("Chargement developpeurs KO : {}".format(e))

# --- 8.2 Helpers d'extraction (puissance, surface, date) ---------------------

def _extract_power_mw(t: str) -> Optional[float]:
    m = _RE_POWER.search(t)
    if not m:
        return None
    try:
        v = float(m.group(1).replace(",","."))
        return v if 0.05 <= v <= 2000 else None
    except ValueError:
        return None

def _extract_area_ha(t: str) -> Optional[float]:
    m = _RE_AREA.search(t)
    if not m:
        return None
    try:
        v = float(m.group(1).replace(",","."))
        return v if 0.1 <= v <= 5000 else None
    except ValueError:
        return None

def _extract_date(text: str) -> Optional[str]:
    _M = {"janvier":1,"fevrier":2,"mars":3,"avril":4,"mai":5,"juin":6,
          "juillet":7,"aout":8,"septembre":9,"octobre":10,"novembre":11,"decembre":12}
    tn = _normalize(text)
    m  = _RE_DATE_TEXT.search(tn)
    if m:
        mo = _M.get(m.group(2).lower())
        y  = int(m.group(3))
        if mo and 2000 <= y <= 2030:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, int(m.group(1)))
    m = _RE_DATE_NUM.search(text)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= d <= 31 and 1 <= mo <= 12 and 2000 <= y <= 2030:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, d)
    return None

# --- 8.3 Helpers de detection (porteur, communes, pertinence) ----------------

def _detect_developer(t: str) -> Optional[str]:
    """Detecte le porteur ENR depuis le texte normalise.
    Cherche le nom canonique ET la racine du domaine (ex: 'energiter').
    """
    for name, domain_hint in _DEVELOPER_NAMES:
        if _normalize(name) in t or domain_hint in t:
            return name
    return None

def _detect_communes_in_text(text_norm: str, communes: List[dict]) -> List[str]:
    return [c["nom"] for c in communes
            if c.get("nom") and len(c["nom"]) >= 4 and _normalize(c["nom"]) in text_norm]

def _compute_relevance(text_norm: str, communes_found: List[str],
                       enr_type: str, matched_commune: Optional[str] = None) -> float:
    if len(text_norm) < 200:
        return 0.0
    eff = communes_found if communes_found else ([matched_commune] if matched_commune else [])
    if not eff:
        return 0.0
    enr_kws  = ENR_KEYWORDS.get(enr_type, [])
    enr_hits = sum(1 for k in enr_kws if k in text_norm)
    if enr_hits == 0:
        return 0.0
    sig_hits = sum(1 for k in PROJECT_SIGNAL_KEYWORDS if k in text_norm)
    return round(min(1.0, 0.4 + min(0.4, 0.1*sig_hits) + min(0.2, 0.05*(enr_hits-1))), 2)

# --- 8.4 Helpers de statut et de titre (specifiques DSFR) --------------------

def _detect_statut(text_norm: str) -> Optional[str]:
    for statut, patterns in _STATUT_PATTERNS:
        if any(_normalize(p) in text_norm for p in patterns):
            return statut
    return None

def _statut_from_hub_url(hub_url: str) -> Optional[str]:
    u = hub_url.lower()
    if any(k in u for k in ("enquetes-publiques", "enquete-publique")):
        return "enquete_publique"
    if any(k in u for k in ("installations-classees", "icpe",
                             "autorisation-environnementale")):
        return "instruction"
    if "autorisations" in u:
        return "autorise"
    return None

def _extract_commune_from_title(title: str) -> Optional[str]:
    m = _RE_COMMUNE_TITLE.search(title or "")
    return m.group(1).strip() if m else None

def _parse_pub_date(s: str) -> Optional[str]:
    """'Publié le 04/05/2026' -> '2026-05-04'"""
    m = re.search(r"(\d{1,2})/(\d{1,2})/(\d{4})", s or "")
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= d <= 31 and 1 <= mo <= 12 and 2000 <= y <= 2030:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, d)
    return None

def _extract_resume(text: str, enr_type: str, max_chars: int = 350) -> Optional[str]:
    if not text:
        return None
    kws = ENR_KEYWORDS.get(enr_type, [])
    for sent in re.split(r'(?<=[.!?])\s+', text):
        sent = sent.strip()
        if len(sent) < 40:
            continue
        if any(k in _normalize(sent) for k in kws):
            return sent[:max_chars]
    return text[:max_chars]

def _clean_nom_projet(title: str) -> str:
    """Normalise le titre d un projet ENR en supprimant le bruit administratif.

    Transformations (dans l ordre) :
      1. Supprime le suffixe de localisation (a Commune (18), sur la commune de...)
      2. Extrait le lieu-dit s il est present
      3. Coupe tout apres le premier tiret si lieu-dit extrait
      4. Supprime les prefixes verbaux (Construction/Creation/Realisation d une...)
      5. Gere "X et Y en projet" -> "Projet de X"
      6. Supprime "Projet de" seul devant le type
      7. Supprime l article initial (Une, Un)
      8. Supprime la puissance (d environ 7 MWc)
      9. Formate : "Type [- Lieu-dit]"

    Note : tous les caracteres speciaux sont specifies litteralement.
    Pas d echappements \\uXXXX dans des raw strings Python.
    Extensible pour eolien et agrivoltaique (memes patterns structurels).
    """
    if not title:
        return title

    t = title.strip()
    lieu_dit = None

    # --- 1. Supprimer le suffixe de localisation (TOUJOURS EN PREMIER) ---
    # Detection sur le texte NORMALISE (ASCII-only) pour eviter les problemes
    # d encodage avec les caracteres accentues dans les patterns regex.
    # _normalize() preserve la longueur → m.start() indexe l original.
    t_norm = _normalize(t)
    _LOC = re.compile(
        r'\s+(?:'
        r'a\s+[a-z][\w-]+(?:\s+[a-z][\w-]+)*\s*(?:\(\d{2,3}\))?'
        r"|sur\s+la\s+commune\s+d(?:e\s+|[''`])\s*[a-z][\w\s-]*?(?:\s*\(\d{2,3}\))?"
        r'|sur\s+les\s+communes\s+de\s+[a-z][\w\s,-]*?(?:\s*\(\d{2,3}\))?'
        r"|sur\s+le\s+territoire\s+d(?:e\s+|[''`])\s*[a-z][\w\s-]*?(?:\s*\(\d{2,3}\))?"
        r')\s*$'
    )
    m_loc = _LOC.search(t_norm)
    if m_loc:
        t = t[:m_loc.start()]

    # --- 2. Extraire le lieu-dit ---

    # 2a. "- Lieu-dit « Les Clairs »" ou "- Lieu-dit Les Clairs" en fin
    m = re.search(r'\s*[-–—]\s*lieu.?dit\s*[«"]?\s*(.+?)\s*[»"]?\s*$', t, re.IGNORECASE)
    if m:
        lieu_dit = m.group(1).strip().strip('«»"')
        t = t[:m.start()]

    # 2b. "au lieu-dit Chêne des Pendus" en fin (localisation deja supprimee)
    if not lieu_dit:
        m = re.search(r'\s+au\s+lieu.?dit\s*[«"]?\s*(.+?)\s*[»"]?\s*$', t, re.IGNORECASE)
        if m:
            lieu_dit = m.group(1).strip().strip('«»"')
            t = t[:m.start()]

    # 2c. "« La Brande des Grands Cours »" ou '"Nom"' en fin
    if not lieu_dit:
        m = re.search(r'\s*[«"]\s*(.+?)\s*[»"]\s*$', t)
        if m:
            lieu_dit = m.group(1).strip()
            t = t[:m.start()]

    # --- 3. Couper apres le premier tiret si lieu-dit extrait ---
    if lieu_dit:
        t = re.sub(r'\s*[-–—]\s*.+$', '', t)

    # --- 4. Supprimer les prefixes verbaux ---
    t = re.sub(
        r"^(?:projet\s+de\s+)?"
        r"(?:r[ée]alisation|construction|cr[ée]ation|"
        r"mise\s+en\s+(?:place|service)|implantation|d[ée]veloppement|installation)"
        r"\s+d['']\s*(?:une?\s+|un\s+)",
        '', t, flags=re.IGNORECASE)
    t = re.sub(
        r"^(?:construction|cr[ée]ation|r[ée]alisation|installation|implantation)"
        r"\s+d['']\s*(?:une?\s+|un\s+)",
        '', t, flags=re.IGNORECASE)

    # --- 5. "X et Y en projet" -> "Projet de X" ---
    if re.search(r'\s+en\s+projet\s*$', t, re.IGNORECASE):
        t = re.sub(r'\s+en\s+projet\s*$', '', t, flags=re.IGNORECASE)
        t = re.sub(
            r"\s+et\s+un[e']?\s+(?!(?:parc|centrale|installation|projet|panneau)).+$",
            '', t, flags=re.IGNORECASE)
        t = re.sub(r'^(?:une?\s+|un\s+)', '', t, flags=re.IGNORECASE)
        t = t.strip()
        return 'Projet de ' + (t[0].lower() + t[1:] if t else t)

    # --- 6. Supprimer "Projet de" seul devant le type ---
    t = re.sub(r'^projet\s+de\s+', '', t, flags=re.IGNORECASE)

    # --- 7. Supprimer l article initial ---
    t = re.sub(r'^(?:une?\s+|un\s+)', '', t, flags=re.IGNORECASE)

    # --- 8. Supprimer la puissance ---
    t = re.sub(r"\s+d['']\s*environ\s+[\d,.]+\s*MWc?\b", '', t, flags=re.IGNORECASE)
    t = re.sub(r"\s+de\s+[\d,.]+(?:\s*à\s*[\d,.]+)?\s*MWc?\b", '', t, flags=re.IGNORECASE)

    # --- Nettoyage et capitalisation ---
    t = t.strip().strip('-–—').strip()
    if t:
        t = t[0].upper() + t[1:]
    if lieu_dit:
        lieu_dit = lieu_dit[0].upper() + lieu_dit[1:] if lieu_dit else lieu_dit
        t = (t + ' - ' + lieu_dit) if t else lieu_dit

    return t


# --- 8.5 Helpers de qualification (regles de selection robuste) --------------

# Règle 1 : URLs de listing/tag/categorie — jamais un article sur un projet unique.
_RE_LISTING_URL = re.compile(
    r'/(?:tag|tags|category|categorie|topic|topics|dossier|'
    r'auteur|author|archive|archives|search|recherche)/'
    r'|/page/\d+/?(?:\?|$)'
    r'|\?(?:s=|q=|search=|tag=)',
    re.I
)

def _is_listing_url(url: str) -> bool:
    """True si l URL est une page de listing (tag, categorie, page/N, ...).
    Ces pages aggregent plusieurs articles et ne decrivent pas un projet unique.
    """
    try:
        return bool(_RE_LISTING_URL.search(url))
    except Exception as e:
        logger.warning("_is_listing_url erreur sur {} : {}".format(url[:80], e))
        return False

def _commune_from_title(title: str, communes: List[dict]) -> Optional[str]:
    """Retourne la premiere commune du rayon trouvee dans le titre, ou None.
    Utilise une frontiere de mot pour eviter les faux positifs :
    ex. 'Meillant' ne doit pas matcher dans 'Chateaumeillant'.
    """
    title_norm = _normalize(title or "")
    for c in communes:
        nom = c.get("nom") or ""
        if len(nom) >= 4:
            pattern = r'(?<![a-z])' + re.escape(_normalize(nom)) + r'(?![a-z])'
            if re.search(pattern, title_norm):
                return nom
    return None

# Règle 3 : types de sources necessitant la commune dans le titre OU l URL.
# Les sources officielles (crawl_index) valident deja la commune en amont.
_STRICT_SOURCE_TYPES = {"presse_specialisee", "presse_locale", "developer"}

# Règle B (dept) : regex codes postaux pour valider le departement.
_RE_ZIPCODE = re.compile(r'\b(0[1-9]|[1-8]\d|9[0-5]|2[AB])\d{3}\b')

def _wrong_dept(text_norm: str, dept_code: str) -> bool:
    """True si le texte contient des codes postaux d un autre departement
    sans aucun code du bon departement.
    """
    dept2   = dept_code.lstrip("0")[:2]
    found   = _RE_ZIPCODE.findall(text_norm)
    if not found:
        return False
    home    = [z for z in found if z.lstrip("0") == dept2 or z == dept_code[:2]]
    foreign = [z for z in found if z.lstrip("0") != dept2 and z != dept_code[:2]]
    return bool(foreign) and not bool(home)

# --- 8.6 Extraction principale depuis le texte fetche ------------------------

def extract_candidate_from_text(
    text: Optional[str], title: Optional[str], snippet: Optional[str],
    communes: List[dict], enr_type: str,
    matched_commune: Optional[str] = None,
    pub_date: Optional[str] = None,
    hub_statut: Optional[str] = None,
    dept_code: Optional[str] = None,
    source_type: Optional[str] = None,
    url: Optional[str] = None,
) -> dict:
    # Règle 1 : rejeter immediatement les pages de listing
    if url and _is_listing_url(url):
        return {"status": "not_relevant", "method": "regex",
                "is_enr_project": False, "relevance_score": 0.0, "candidate": None}

    if not text or len(text) < 100:
        return {"status": "skipped_no_text", "method": None,
                "is_enr_project": None, "relevance_score": 0.0, "candidate": None}

    full      = " ".join(filter(None, [title or "", snippet or "", text]))
    full_norm = _normalize(full)
    cf        = _detect_communes_in_text(full_norm, communes)

    # Valider matched_commune contre le texte fetche
    effective_commune = matched_commune
    if effective_commune and _normalize(effective_commune) not in full_norm:
        effective_commune = None

    rel = _compute_relevance(full_norm, cf, enr_type,
                             matched_commune=effective_commune)
    if rel < 0.4:
        return {"status": "not_relevant", "method": "regex",
                "is_enr_project": False, "relevance_score": rel, "candidate": None}

    # Règle B : departement etranger
    if dept_code and _wrong_dept(full_norm, dept_code):
        return {"status": "not_relevant", "method": "regex",
                "is_enr_project": False, "relevance_score": rel, "candidate": None}

    # Règle 2 + 3 : pour les sources strictes (presse, developer), la commune
    # du rayon doit apparaitre dans le titre OU dans le chemin de l URL.
    # - titre : "Projet photovoltaique a Contres" → ok
    # - URL   : ".../commune/contres/..." → ok
    # - sinon : article sur un autre sujet mentionnant juste notre commune
    title_commune = _commune_from_title(title, communes)
    if source_type in _STRICT_SOURCE_TYPES:
        url_norm = _normalize(url or "").replace("-", " ").replace("/", " ")
        commune_in_url = any(
            len(c["nom"]) >= 4 and _normalize(c["nom"]) in url_norm
            for c in communes if c.get("nom")
        )
        if not title_commune and not commune_in_url:
            return {"status": "not_relevant", "method": "regex",
                    "is_enr_project": False, "relevance_score": rel, "candidate": None}

    # Commune authoritative : titre > effective_commune > detection generique
    cm = title_commune or effective_commune or (cf[0] if cf else None)

    power  = _extract_power_mw(full_norm)
    area   = _extract_area_ha(full_norm)
    dev    = _detect_developer(full_norm)
    statut = _detect_statut(full_norm) or hub_statut
    date   = _extract_date(full) or _parse_pub_date(pub_date)
    resume = _extract_resume(text, enr_type)

    cand = {
        "nom_projet":     _clean_nom_projet(title[:200]) if title else None,
        "commune":        cm,
        "communes_all":   cf,
        "type_enr":       enr_type,
        "puissance_mw":   power,
        "superficie_ha":  area,
        "maitre_ouvrage": dev,
        "date_annonce":   date,
        "statut":         statut,
        "resume_court":   resume,
        "confidence":     rel,
    }

    signals = sum(x is not None for x in (power, area, dev))

    # extracted_direct : >= 2 signaux chiffres (puissance, surface, porteur)
    if signals >= 2:
        return {"status": "extracted_direct", "method": "regex",
                "is_enr_project": True, "relevance_score": rel, "candidate": cand}

    # Règle 4 : extracted_partial necessite statut OU signal >= 1.
    # Le resume seul ne suffit plus (trop permissif pour les articles generaux).
    if cm and (statut or signals >= 1):
        return {"status": "extracted_partial", "method": "regex",
                "is_enr_project": True, "relevance_score": rel, "candidate": cand}

    return {"status": "needs_llm", "method": "regex",
            "is_enr_project": None, "relevance_score": rel, "candidate": cand}

def _extraction_from_internal(url_entry: dict, enr_type: str) -> dict:
    extra = url_entry.get("extra") or {}
    cand  = {
        "nom_projet":     _clean_nom_projet(url_entry.get("title") or ""),
        "commune":        url_entry.get("matched_commune"),
        "communes_all":   [url_entry.get("matched_commune")] if url_entry.get("matched_commune") else [],
        "type_enr":       enr_type,
        "puissance_mw":   extra.get("puissance_mw"),
        "superficie_ha":  extra.get("superficie_ha"),
        "maitre_ouvrage": extra.get("maitre_ouvrage"),
        "date_annonce":   extra.get("date_avis"),
        "statut":         extra.get("avis_type"),
        "resume_court":   url_entry.get("snippet"),
        "confidence":     1.0,
        "mrae_ref":       extra.get("reference_cle"),
        "mrae_pdf":       extra.get("pdf_path"),
    }
    return {"status":"internal","method":"internal","is_enr_project":True,
            "relevance_score":1.0,"candidate":cand}

# --- 8.6 Persistance et orchestration extraction -----------------------------

def _save_extraction(job_id: str, url: str, result: dict, duration: float,
                     error: Optional[str] = None) -> None:
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO news.job_results
                    (url,job_id,status,method,is_enr_project,
                     relevance_score,candidate,duration,error)
                VALUES(%(url)s,%(job_id)s,%(status)s,%(method)s,%(is_enr_project)s,
                       %(relevance_score)s,%(candidate)s::jsonb,%(duration)s,%(error)s)
                ON CONFLICT(url,job_id) DO UPDATE SET
                    status=EXCLUDED.status,method=EXCLUDED.method,
                    is_enr_project=EXCLUDED.is_enr_project,
                    relevance_score=EXCLUDED.relevance_score,
                    candidate=EXCLUDED.candidate,duration=EXCLUDED.duration,
                    error=EXCLUDED.error,extracted_at=NOW()
                """,
                {"url":url,"job_id":job_id,"status":result["status"],
                 "method":result.get("method"),"is_enr_project":result.get("is_enr_project"),
                 "relevance_score":result.get("relevance_score"),
                 "candidate":json.dumps(result.get("candidate")) if result.get("candidate") else None,
                 "duration":duration,"error":error},
            )
            conn.commit()
    finally:
        conn.close()

def extract_all_candidates(job_id: str, urls: List[dict], fetched_by_url: dict,
                           communes: List[dict], enr_type: str,
                           dept_code: Optional[str] = None) -> dict:
    """Phase 4b : extraction regex (puissance, surface, porteur, date, statut, resume)."""
    stats = {"total":len(urls),"not_relevant":0,"extracted_direct":0,
             "needs_llm":0,"internal":0,"skipped_no_text":0,"error":0}
    start = time.time()
    for u in urls:
        url = u["url"]
        t0  = time.time()
        try:
            if url.startswith("internal://"):
                result = _extraction_from_internal(u, enr_type)
            else:
                cache  = fetched_by_url.get(url)
                result = extract_candidate_from_text(
                    text=cache.get("text") if cache else None,
                    title=u.get("title"), snippet=u.get("snippet"),
                    communes=communes, enr_type=enr_type,
                    matched_commune=u.get("matched_commune"),
                    pub_date=u.get("pub_date"),
                    hub_statut=u.get("hub_statut"),
                    dept_code=dept_code,
                    source_type=u.get("source_type"),
                    url=url,
                )
            _save_extraction(job_id, url, result, time.time()-t0)
            stats[result["status"]] = stats.get(result["status"], 0) + 1
        except Exception as e:
            logger.exception("Echec extraction {}".format(url))
            _save_extraction(job_id, url,
                {"status":"error","method":None,"is_enr_project":None,
                 "relevance_score":0.0,"candidate":None},
                time.time()-t0, error=str(e)[:500])
            stats["error"] += 1
    logger.info("  Regex : {} URLs en {:.1f}s (direct={},needs_llm={},internal={},"
                "not_relevant={},skipped={},err={})".format(
                    len(urls), time.time()-start,
                    stats["extracted_direct"], stats["needs_llm"], stats["internal"],
                    stats["not_relevant"], stats["skipped_no_text"], stats["error"]))
    return stats

# ==============================================================================
#  9. PHASES 5-8 : CONSOLIDATION ET EXPORT
#     Filtre ENR, regroupement par projet, export CSV.
# ==============================================================================

def _filter_enr_projects(projects: List[dict]) -> List[dict]:
    """Phase 5 : filtre ENR — conserve uniquement photovoltaique, agrivoltaique, eolien."""
    out = []
    for p in projects:
        # 1. Champ type_enr renseigne et dans la cible
        if p.get("type_enr") in ENR_TYPES_TARGET:
            out.append(p)
            continue
        # 2. Fallback : presence de mots-cles ENR cible dans titre ou resume
        haystack = _normalize(
            (p.get("nom_projet") or "") + " " + (p.get("resume_court") or ""))
        if any(k in haystack for k in ENR_KEYWORDS_TARGET):
            out.append(p)
    return out

def consolidate_projects(projects: List[dict]) -> List[dict]:
    """Phase 6 : regroupe les candidats par projet unique (1 ligne = 1 projet).

    Cle de regroupement :
      - commune + type_enr + porteur normalise        (cas principal)
      - commune + type_enr + mots-cles nom_projet     (fallback si porteur absent)
      - commune + type_enr + source_url               (dernier recours : ligne unique)

    Pour chaque groupe :
      - La source de meilleure priorite fournit les champs de base.
      - Les champs manquants sont completes depuis les autres sources.
      - Toutes les URLs sont conservees dans `sources`.
    """
    _PRIORITY  = {"internal":1,"extracted_direct":2,"extracted_llm":3,"extracted_partial":4}
    _STOP_WORDS = {"projet","de","d","la","le","les","du","des","une","un","sur","au",
                   "aux","en","et","l","creation","realisation","construction",
                   "installation","centrale","parc","ferme","solaire","energie"}
    _FILLABLE  = ("puissance_mw","superficie_ha","maitre_ouvrage",
                  "date_annonce","statut","resume_court","nom_projet")

    def _kw(s: str) -> frozenset:
        words = _normalize(s or "").split()
        return frozenset(w for w in words if w not in _STOP_WORDS and len(w) > 3)

    def _group_key(p: dict) -> str:
        commune = _normalize(p.get("commune") or "")
        enr     = p.get("type_enr") or ""
        porteur = _normalize(p.get("maitre_ouvrage") or "")
        if porteur:
            return "{}|{}|{}".format(commune, enr, porteur)
        kw = _kw(p.get("nom_projet") or "")
        if len(kw) >= 2:
            return "{}|{}|{}".format(commune, enr, "|".join(sorted(kw)[:4]))
        return "{}|{}|{}".format(commune, enr, p.get("source_url", ""))

    # Groupement
    groups: dict = {}
    for p in projects:
        key = _group_key(p)
        groups.setdefault(key, []).append(p)

    # Fusion de chaque groupe
    consolidated = []
    for group in groups.values():
        # Trier par priorite de source (meilleure en premier)
        group.sort(key=lambda p: (
            _PRIORITY.get(p.get("source_status", ""), 99),
            -sum(1 for f in _FILLABLE if p.get(f)),
        ))
        base = dict(group[0])

        # Completer les champs manquants depuis les sources suivantes
        for other in group[1:]:
            for field in _FILLABLE:
                if not base.get(field) and other.get(field):
                    base[field] = other[field]

        # Consolider les sources
        base["sources"]      = [p["source_url"] for p in group]
        base["source_count"] = len(group)
        base["source_status"] = group[0].get("source_status", "")
        consolidated.append(base)

    return consolidated

_LLM_NAMES_SYSTEM = (
    "Tu normalises des noms de projets ENR francais. "
    "SUPPRIMER : communes, codes departement, puissances (MWc/MW), verbes admin "
    "(Projet de, Creation d une, Realisation d un(e), Construction d un(e), Implantation). "
    "CONSERVER : type de projet (Centrale PV / Centrale photovoltaique / Parc photovoltaique / "
    "Parc eolien / Centrale eolienne / Projet agrivoltaique) + lieu-dit ou nom specifique si present. "
    "FORMAT : 'Type' ou 'Type - Lieu-dit'. "
    "Si le nom ne contient pas de type ENR reconnaissable, renvoie-le tel quel. "
    "Reponds UNIQUEMENT avec {\"r\": [\"nom1\", \"nom2\", ...]} dans le meme ordre que l entree, "
    "sans commentaire ni texte supplementaire."
)

def _call_llm_names(names: List[str]) -> Optional[List[str]]:
    """Appel Ollama batch pour normaliser les noms de projets ENR.

    Retourne la liste normalisee (meme longueur que l entree) ou None si echec.
    Temperature 0 pour une sortie deterministe et stable.
    """
    if not names:
        return []
    prompt = "Normalise ces noms :\n" + json.dumps(names, ensure_ascii=False, indent=None)
    raw = ""
    try:
        resp = httpx.post(
            "{}/api/generate".format(OLLAMA_HOST),
            json={
                "model":  OLLAMA_MODEL,
                "system": _LLM_NAMES_SYSTEM,
                "prompt": prompt,
                "format": "json",
                "stream": False,
				"keep_alive": "5m",
                "options": {
                    "temperature": 0,
                    "num_predict": 512,
                    "num_ctx":    2048,
                },
            },
            timeout=OLLAMA_TIMEOUT_NAMES,
        )
        resp.raise_for_status()
        raw = resp.json().get("response", "").strip()
        if raw.startswith("```"):
            raw = raw.lstrip("`").lstrip("json").strip().rstrip("`").strip()
        parsed = json.loads(raw)
        # Accepter plusieurs cles possibles en sortie
        result = (parsed.get("r") or parsed.get("results") or
                  parsed.get("noms") or parsed.get("names"))
        if not isinstance(result, list):
            logger.warning("LLM noms : reponse sans liste | raw={!r:.80}".format(raw[:80]))
            return None
        if len(result) != len(names):
            logger.warning("LLM noms : longueur {} vs {} attendus".format(
                len(result), len(names)))
            return None
        return [str(n).strip() or names[i] for i, n in enumerate(result)]
    except json.JSONDecodeError as e:
        logger.warning("LLM noms JSON invalide : {} | raw={!r:.80}".format(e, raw[:80]))
        return None
    except Exception as e:
        logger.warning("LLM noms echec : {}".format(e))
        return None

def _apply_llm_names(projects: List[dict]) -> List[dict]:
    """Normalise les nom_projet de tous les projets via un seul appel LLM batch.

    Pipeline :
      1. Soumet tous les noms en un appel unique (rapide meme pour 20 projets)
      2. Valide que la reponse a la meme longueur que l entree
      3. Applique seulement les noms non vides (>= 5 chars)
      4. Fallback transparent : conserve le nom existant en cas d echec partiel

    Branche uniquement si OLLAMA_ENABLED=true.
    """
    if not projects:
        return projects

    names_in  = [p.get("nom_projet") or "" for p in projects]
    t0 = time.time()
    logger.info("  LLM noms : {} projets -> {}".format(len(names_in), OLLAMA_HOST))

    names_out = _call_llm_names(names_in)

    if names_out is None:
        logger.warning("  LLM noms : echec, noms originaux conserves")
        return projects

    applied = 0
    for p, new_name in zip(projects, names_out):
        if new_name and len(new_name) >= 5:
            p["nom_projet"] = new_name
            applied += 1

    logger.info("  LLM noms : {}/{} noms normalises en {:.1f}s".format(
        applied, len(projects), time.time() - t0))
    return projects

def _export_projects_file(projects: List[dict], job_id: str,
                           commune: str, dept_code: str,
                           radius_km: int) -> Optional[str]:
    """Phase 8 : export CSV (separateur ;, encodage utf-8-sig pour Excel FR)."""
    import csv, os
    out_dir = "/app/output"
    os.makedirs(out_dir, exist_ok=True)

    ts       = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = "projects_{}_{}_{}km_{}.csv".format(
        commune.replace(" ", "-"), dept_code, radius_km, ts)
    filepath = os.path.join(out_dir, filename)

    fieldnames = ["commune","distance","nom_projet","puissance_mw","superficie_ha",
                  "maitre_ouvrage","statut","date_annonce","resume_court",
                  "source_count","sources","source_status"]

    TEXT_FIELDS = {"nom_projet", "maitre_ouvrage", "resume_court"}

    def _clean_row(p: dict) -> dict:
        row = {}
        for f in fieldnames:
            v = p.get(f)
            if v is None:
                row[f] = ""
            elif f == "sources":
                # Liste d URLs separees par |
                row[f] = " | ".join(v) if isinstance(v, list) else (v or "")
            elif f in TEXT_FIELDS and isinstance(v, str):
                row[f] = " ".join(v.split())
            else:
                row[f] = v
        return row

    try:
        with open(filepath, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore",
                               delimiter=";")
            w.writeheader()
            w.writerows(_clean_row(p) for p in projects)
        logger.info("  Export CSV : {}".format(filepath))
        return filepath
    except Exception as e:
        logger.warning("  Export CSV KO : {}".format(e))
        return None

def _build_project_summary(job_id: str, communes: List[dict]) -> List[dict]:
    """Construit la liste des projets detectes pour un job, triee par distance."""
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                SELECT url, status, method, candidate
                FROM news.job_results
                WHERE job_id = %s
                  AND status IN ('internal','extracted_direct',
                                 'extracted_partial','extracted_llm')
                ORDER BY
                    CASE status
                        WHEN 'internal'          THEN 1
                        WHEN 'extracted_direct'  THEN 2
                        WHEN 'extracted_llm'     THEN 3
                        WHEN 'extracted_partial' THEN 4
                    END
                """,
                (job_id,),
            )
            rows = [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()

    # Index des communes par nom pour retrouver la distance
    commune_by_nom = {c["nom"]: c for c in communes}

    projects = []
    for row in rows:
        cand = row.get("candidate") or {}
        if isinstance(cand, str):
            try:
                cand = json.loads(cand)
            except Exception:
                cand = {}

        commune_nom = cand.get("commune") or "?"
        c_info      = commune_by_nom.get(commune_nom)
        dist_str    = ""
        if c_info:
            dist_km  = (c_info["distance_m"] or 0) / 1000
            dist_str = "{:.1f} km".format(dist_km)

        projects.append({
            "nom_projet":     (cand.get("nom_projet") or "?")[:80],
            "commune":        commune_nom,
            "distance":       dist_str,
            "puissance_mw":   cand.get("puissance_mw"),
            "superficie_ha":  cand.get("superficie_ha"),
            "maitre_ouvrage": cand.get("maitre_ouvrage"),
            "statut":         cand.get("statut"),
            "date_annonce":   cand.get("date_annonce"),
            "resume_court":   (cand.get("resume_court") or "")[:200],
            "source_url":     row["url"],
            "source_status":  row["status"],
            "confidence":     cand.get("confidence"),
        })

    # Trier par distance croissante
    def _dist_key(p):
        try:
            return float(p["distance"].replace(" km", ""))
        except Exception:
            return 999.0

    projects = sorted(projects, key=_dist_key)

    before_filter = len(projects)
    projects = _filter_enr_projects(projects)
    before_consol = len(projects)
    projects = consolidate_projects(projects)

    if OLLAMA_ENABLED:
        projects = _apply_llm_names(projects)

    logger.info("  Resume : {} bruts -> {} apres filtre ENR -> {} apres consolidation".format(
        before_filter, before_consol, len(projects)))

    return projects

# ==============================================================================
#  10. ORCHESTRATION JOB
#      Prend en charge un job depuis la queue Redis jusqu a l export CSV.
# ==============================================================================

def process_job(r, job_id: str) -> None:
    logger.info("=== Job {} ===".format(job_id))
    job = _load_job(r, job_id)
    if job is None:
        logger.error("Job {} introuvable".format(job_id))
        return

    t0 = time.monotonic()
    _update_job(r, job_id, status="processing", started_at=_now_iso(),
                progress={"step":"consulting_registry"})

    commune   = job["commune"]
    dept_code = job["dept_code"]
    enr_type  = job["enr_type"]
    radius_km = job.get("radius_km", 10)
    region    = region_of(dept_code)

    if region is None:
        logger.warning("Region inconnue pour dept_code={}".format(dept_code))
    logger.info("Traitement : {} (dept={}, region={}) type={} r={}km".format(
        commune, dept_code, region or "?", enr_type, radius_km))

    try:
        # Etape 1 : sources
        sources   = get_candidate_sources(dept_code, enr_type)
        enr_label = get_enr_label(enr_type)
        logger.info("  {} sources (label='{}')".format(len(sources), enr_label))
        for s in sources[:3]:
            logger.info("    {:>5.2f}  {:<35}  ({})".format(
                s["final_score"], s["domain"], s["niveau"]))
        if len(sources) > 3:
            logger.info("    ... et {} autres".format(len(sources)-3))

        # Etape 2 : communes
        _update_job(r, job_id, progress={"step":"resolving_communes","sources_found":len(sources)})
        communes = get_target_communes(commune, dept_code, radius_km)
        if not communes:
            logger.warning("Commune '{}' introuvable -- fallback".format(commune))
            communes = [{"insee_com":None,"nom":commune,"population":None,
                         "distance_m":0.0,"is_origin":True}]
        logger.info("  {} communes dans {}km".format(len(communes), radius_km))
        communes_for_search = communes
        if MAX_COMMUNES_PER_JOB > 0 and len(communes) > MAX_COMMUNES_PER_JOB:
            communes_for_search = communes[:MAX_COMMUNES_PER_JOB]
        for c in communes[:5]:
            logger.info("    {:>6.0f}m  {}".format(c["distance_m"], c["nom"]))
        if len(communes) > 5:
            logger.info("    ... et {} autres".format(len(communes)-5))

        # Etape 3 : collecte (Phases 1 + 2 + 3)
        _update_job(r, job_id, progress={"step":"searching_web","communes_target":len(communes)})
        urls      = collect_urls_for_sources(
            sources=sources, communes_all=communes,
            communes_for_search=communes_for_search,
            enr_type=enr_type, enr_label=enr_label,
        )
        by_method = {"internal":0,"crawl_index":0,"searxng":0,"free_search":0}
        for u in urls:
            by_method[u["method"]] = by_method.get(u["method"],0) + 1
        logger.info("  {} URLs (int={},crawl={},searxng={},free={})".format(
            len(urls), by_method["internal"], by_method["crawl_index"],
            by_method["searxng"], by_method["free_search"]))

        # Etape 4a : fetch
        _update_job(r, job_id, progress={"step":"fetching_content","urls_found":len(urls)})
        fetched        = fetch_urls_parallel([u["url"] for u in urls])
        fetch_stats    = fetched["stats"]
        fetched_by_url = fetched["results"]
        for u in urls:
            f = fetched_by_url.get(u["url"])
            u["fetch"] = ({"method":"skipped","reason":"internal"} if f is None else {
                "method":f.get("fetch_method"),"http_status":f.get("http_status"),
                "content_type":f.get("content_type"),"text_length":f.get("text_length"),
                "fetch_duration":round(f.get("fetch_duration") or 0.0, 2),
                "from_cache":f.get("from_cache",False),"error":f.get("error"),
            })

        # Etape 4b : extraction regex
        _update_job(r, job_id, progress={"step":"extracting_candidates","urls_found":len(urls)})
        extract_stats = extract_all_candidates(
            job_id=job_id, urls=urls, fetched_by_url=fetched_by_url,
            communes=communes, enr_type=enr_type, dept_code=dept_code,
        )

        # Comptage final
        total_candidates = (extract_stats["extracted_direct"]
                            + extract_stats["internal"]
                            + extract_stats.get("extracted_partial", 0))

        result = {
            "commune":commune,"dept_code":dept_code,"enr_type":enr_type,
            "enr_label":enr_label,"radius_km":radius_km,
            "sources":sources,"total_sources":len(sources),
            "target_communes":communes,"total_communes":len(communes),
            "urls":urls,"total_urls":len(urls),"urls_by_method":by_method,
            "fetch_stats":fetch_stats,"extract_stats":extract_stats,
            "total_candidates":total_candidates,
        }

        _update_job(r, job_id, status="done", finished_at=_now_iso(), result=result,
                    progress={"step":"done","candidates":total_candidates})

        # Phases 5-8 : consolidation et export
        projects = _build_project_summary(job_id, communes)
        result["projects"] = projects

        csv_path = _export_projects_file(
            projects, job_id, commune, dept_code, radius_km)
        if csv_path:
            result["export_csv"] = csv_path

        logger.info(
            "Job {} fini en {:.1f}s : {} communes -> {} URLs -> "
            "{} fetch -> {} projets consolides (export: {})".format(
                job_id[:8], time.monotonic()-t0, len(communes), len(urls),
                fetch_stats["html"]+fetch_stats["pdf"],
                len(projects), csv_path or "KO",
            )
        )

    except Exception as e:
        logger.exception("Erreur job {} apres {:.1f}s".format(job_id, time.monotonic()-t0))
        _update_job(r, job_id, status="error", finished_at=_now_iso(), error=str(e)[:500])

# ==============================================================================
#  11. BOUCLE WORKER ET MAIN
#      Gestion du signal d arret, boucle BRPOP, initialisation.
# ==============================================================================

_shutdown = False

def _on_signal(signum, frame):
    global _shutdown
    logger.info("Signal {} recu".format(signum))
    _shutdown = True

signal.signal(signal.SIGTERM, _on_signal)
signal.signal(signal.SIGINT,  _on_signal)

def main():
    logger.info("NEWS Scraper agent demarre")

    for attempt in range(10):
        try:
            r = get_redis(); r.ping()
            c = get_db();    c.close()
            break
        except Exception as e:
            logger.warning("Dependances ({}/10) : {}".format(attempt+1, e))
            time.sleep(3)
    else:
        logger.error("Impossible de joindre Redis ou PostgreSQL")
        return

    _load_developer_names()

    r = get_redis()

    while not _shutdown:
        try:
            pop = r.brpop(QUEUE_KEY, timeout=BRPOP_TIMEOUT_SEC)
            if pop is None:
                continue
            _, job_id = pop
            process_job(r, job_id)
        except redis.ConnectionError as e:
            logger.error("Perte Redis : {} -- reconnexion 5s".format(e))
            time.sleep(5)
            r = get_redis()
        except Exception:
            logger.exception("Erreur boucle principale")
            time.sleep(2)

    logger.info("Agent arrete")

if __name__ == "__main__":
    main()
'@
}