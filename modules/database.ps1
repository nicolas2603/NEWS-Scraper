# ==============================================================================
#  modules/database.ps1
#  Generation des fichiers d'infrastructure : .env, docker-compose.yml,
#  init.sql  +  execution du SQL dans le PostgreSQL MRAE partage.
# ==============================================================================

function New-EnvFile {
    param([string]$DBPassword)

    Write-FileUTF8NoBOM -Path $script:CONFIG.EnvFile -Content @"
# NEWS Scraper - Variables d'environnement  (ne pas committer dans git)

# --- Base de donnees (instance partagee MRAE Scraper) ------------------------
DB_HOST=$($script:CONFIG.MRAEPostgres)
DB_PORT=5432
DB_NAME=$($script:CONFIG.DBName)
DB_USER=$($script:CONFIG.DBUser)
DB_PASSWORD=$DBPassword
DB_SCHEMA=news

# --- LLM (Ollama partage avec MRAE Scraper) ----------------------------------
OLLAMA_HOST=http://$($script:CONFIG.MRAEOllama):11434
OLLAMA_MODEL=qwen2.5:7b
OLLAMA_TIMEOUT=120
OLLAMA_NUM_THREAD=8

# --- Moteur de recherche -----------------------------------------------------
# SearXNG auto-heberge sur le reseau Docker interne.
# Aggrege Google, Bing, DuckDuckGo, Qwant... sans cle API, illimite a notre rythme.
SEARXNG_URL=http://news_searxng:8080
SEARXNG_CONCURRENCY=1           # serie pour eviter rate-limit des moteurs agreges

# --- Extraction contenu (reutilisation du conteneur MRAE) --------------------
# Tika extrait le texte des PDFs. Le conteneur mrae_tika est sur mrae_network.
TIKA_URL=http://mrae_tika:9998

# --- Fetch URLs --------------------------------------------------------------
FETCH_CONCURRENCY=10            # threads de fetch simultanes (total)
FETCH_PER_DOMAIN_MAX=2          # nb max de fetch simultanes vers un meme host
FETCH_TIMEOUT_SEC=15
FETCH_TEXT_MAX_CHARS=50000      # troncature du texte stocke en cache
URL_CACHE_TTL_DAYS=30

# --- Agent -------------------------------------------------------------------
AGENT_MAX_ITERATIONS=10
AGENT_MAX_PAGES_PER_SEARCH=5
AGENT_MIN_QUALITY_SCORE=0.3
AGENT_SEARCH_RADIUS_KM=30
MAX_COMMUNES_PER_JOB=0          # 0 = pas de limite, prend toutes les communes du rayon
SEARXNG_QUERY_DELAY_SEC=2       # delai entre 2 requetes SearXNG (evite rate-limit)
SEARXNG_CACHE_TTL_HOURS=24      # cache des resultats SearXNG identiques

# --- Redis -------------------------------------------------------------------
REDIS_URL=redis://news_redis:6379/0

# --- Logging -----------------------------------------------------------------
LOG_LEVEL=INFO
"@
}

function New-DockerCompose {
    Write-FileUTF8NoBOM -Path $script:CONFIG.ComposeFile -Content @"
# NEWS Scraper - Docker Compose
# Projet autonome partageant le reseau et les services de MRAE Scraper.
# Prerequis : la stack MRAE doit etre demarree avant de lancer celle-ci.
name: news-scraper

services:

  news_agent:
    build:
      context: ./agent
      dockerfile: Dockerfile
    image: news_agent:latest
    container_name: news_agent
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./agent:/app
      - ./data:/data
    networks:
      - news_net
      - $($script:CONFIG.SharedNetwork)
    depends_on:
      - news_redis
      - news_searxng

  news_redis:
    image: redis:7-alpine
    container_name: news_redis
    restart: unless-stopped
    volumes:
      - ./data/redis:/data
    networks:
      - news_net

  news_searxng:
    image: searxng/searxng:latest
    container_name: news_searxng
    restart: unless-stopped
    # Port expose sur l hote pour debug (http://localhost:8502).
    # En interne, l agent l atteint via http://news_searxng:8080.
    ports:
      - "8502:8080"
    volumes:
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - INSTANCE_NAME=news_searxng
      - BASE_URL=http://news_searxng:8080/
    networks:
      - news_net
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID

  news_api:
    build:
      context: ./api
      dockerfile: Dockerfile
    image: news_api:latest
    container_name: news_api
    restart: unless-stopped
    env_file: .env
    ports:
      - "$($script:CONFIG.AgentPort):8000"
    volumes:
      - ./api:/app
    networks:
      - news_net
      - $($script:CONFIG.SharedNetwork)
    depends_on:
      - news_agent

networks:
  news_net:
    driver: bridge
    name: news_network

  # Reseau partage avec MRAE Scraper (cree par MRAE, externe ici)
  $($script:CONFIG.SharedNetwork):
    external: true
"@
}

function New-InitSQL {
    # @'...'@ = here-string NON-interpolante : les $ ne sont pas interpretes
    # par PowerShell. Indispensable pour les dollar-quotes PostgreSQL ($$, $func$)
    # et toutes les variables SQL du type $1, $2 dans les fonctions.
    $sqlContent = @'
-- ==============================================================================
-- NEWS Scraper - Schema news (migration complete)
--
-- Principe : separation score theorique (a priori metier, stocke dans sources)
-- et score empirique (apprentissage via source_feedback, agrege dans
-- la vue source_scores). Combinaison ponderee dans get_best_sources().
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS news;

-- ==============================================================================
-- Referentiel des types d ENR
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.enr_types (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO news.enr_types (code, label) VALUES
    ('photovoltaique', 'Photovoltaique'),
    ('agrivoltaique',  'Agrivoltaique'),
    ('eolien',         'Eolien'),
    ('stockage',       'Stockage'),
    ('poste',          'Poste electrique'),
    ('biomasse',       'Biomasse'),
    ('hydraulique',    'Hydraulique'),
    ('geothermie',     'Geothermie'),
    ('nucleaire',      'Nucleaire'),
    ('fossile',        'Fossile')
ON CONFLICT (code) DO NOTHING;

-- ==============================================================================
-- Table sources : catalogue des sources web et scores theoriques
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.sources (
    id              SERIAL PRIMARY KEY,
    domain          TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,

    source_type     TEXT NOT NULL,           -- officiel | enquete_publique | infrastructure
                                             -- presse_locale | presse_specialisee | open_data | aggregateur
    signal_type     TEXT CHECK (signal_type IN (
                       'reglementaire', 'enquete', 'presse', 'technique',
                       'open_data', 'developpeur', 'divers'
                    )),
    is_structured   BOOLEAN DEFAULT FALSE,   -- donnees structurees (API/CSV) ou HTML
    is_active       BOOLEAN DEFAULT TRUE,
    is_internal     BOOLEAN DEFAULT FALSE,   -- true = notre propre base (ex: MRAE_DB)

    -- Comment l agent decouvre les URLs de cette source
    --   'searxng_site'  : recherche SearXNG `site:<domain>` (defaut historique)
    --   'searxng_free'  : recherche SearXNG sans 'site:' (decouverte large)
    --   'crawl_index'   : fetch direct de `index_url` + parsing des liens
    --   'internal'      : requete SQL locale (ex: mrae.avis)
    --   'rss'           : flux RSS (a venir)
    discovery_mode  TEXT DEFAULT 'searxng_site' CHECK (discovery_mode IN (
                       'searxng_site', 'searxng_free', 'crawl_index',
                       'internal', 'rss'
                    )),
    -- Pour les sources en mode 'crawl_index' ou 'rss' : URL(s) de la (des)
    -- page(s) d index ou du flux. NULL pour les autres modes.
    -- TEXT[] (array) pour permettre plusieurs paths par source : une
    -- prefecture publie typiquement sur 2-5 pages d index differentes
    -- (Rapport-Enquetes-publiques, AOEP, Participation-du-public, ...).
    index_urls      TEXT[],

    -- Pour les sources 'crawl_index' avec decouverte automatique de hubs :
    -- timestamp de la derniere decouverte. Si trop ancien (TTL configurable
    -- cote agent), une re-decouverte est declenchee avant le crawl.
    -- NULL = pas encore decouvert -> declenche au premier job concerne.
    hubs_discovered_at  TIMESTAMPTZ,

    -- Scores theoriques (a priori metier, entre 0 et 1)
    reliability_score   FLOAT DEFAULT 0.5,   -- confiance globale dans la source
    freshness_score     FLOAT DEFAULT 0.5,   -- frequence de mise a jour
    early_signal_score  FLOAT DEFAULT 0.5,   -- capacite a detecter tot
    cost_score          FLOAT DEFAULT 0.5,   -- difficulte technique du scraping

    created_at      TIMESTAMP DEFAULT NOW()
);

-- ==============================================================================
-- Couverture geographique
-- Index UNIQUE avec COALESCE pour gerer les NULL (compatible Postgres 12+)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.source_coverage (
    id           SERIAL PRIMARY KEY,
    source_id    INT REFERENCES news.sources(id) ON DELETE CASCADE,
    niveau       TEXT CHECK (niveau IN ('national', 'regional', 'departemental', 'communal')),
    region_name  TEXT,
    dept_code    TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_coverage_unique
    ON news.source_coverage (
        source_id,
        niveau,
        COALESCE(region_name, ''),
        COALESCE(dept_code, '')
    );

-- ==============================================================================
-- Affinite source <-> type ENR (connaissance metier, modifiable a la main)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.source_enr_affinity (
    source_id       INT  REFERENCES news.sources(id) ON DELETE CASCADE,
    enr_type_code   TEXT REFERENCES news.enr_types(code),
    affinity_score  FLOAT DEFAULT 0.5,
    PRIMARY KEY (source_id, enr_type_code)
);

-- ==============================================================================
-- Feedback : journal des tentatives, base de l apprentissage
-- On garde tous les champs debug (commune, search_query, url_found, notes)
-- pour pouvoir expliquer a posteriori pourquoi telle source a ete penalisee.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.source_feedback (
    id              SERIAL PRIMARY KEY,
    source_id       INT  REFERENCES news.sources(id),
    enr_type_code   TEXT REFERENCES news.enr_types(code),

    region_name     TEXT,
    dept_code       TEXT,
    commune         TEXT,
    search_query    TEXT,
    url_found       TEXT,

    is_hit          BOOLEAN,
    quality_score   FLOAT,
    notes           TEXT,

    created_at      TIMESTAMP DEFAULT NOW()
);

-- ==============================================================================
-- Cache de fetch d'URLs
--
-- Stocke le texte extrait de chaque URL fetchee pour eviter de refetcher la
-- meme URL a travers plusieurs jobs. TTL configurable cote agent (30 jours par
-- defaut) : une entree plus ancienne est consideree perimee et re-fetchee.
--
-- `text` peut etre NULL en cas d'echec -- on garde quand meme l'entree avec
-- le code HTTP et le message d'erreur pour ne pas retenter immediatement.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.url_cache (
    url             TEXT PRIMARY KEY,
    http_status     INT,
    content_type    TEXT,              -- mime type detecte
    fetch_method    TEXT,              -- 'html' | 'pdf' | 'skipped' | 'error'
    text            TEXT,              -- contenu extrait (tronque a FETCH_TEXT_MAX_CHARS)
    text_length     INT,               -- longueur avant troncature
    fetch_duration  FLOAT,             -- secondes
    error           TEXT,              -- si echec : message d'erreur
    fetched_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_url_cache_fetched ON news.url_cache (fetched_at);

-- ==============================================================================
-- Cache des resultats de recherche SearXNG
--
-- Stocke les resultats bruts d une requete SearXNG (le tableau des hits) pour
-- eviter de re-tirer les memes requetes si le meme job est relance dans la
-- journee. Chaque ligne represente UNE requete (la query exacte).
--
-- TTL : 24h (controle cote agent via la colonne fetched_at).
-- Hygiene : on peut purger periodiquement avec
--   DELETE FROM news.searxng_cache WHERE fetched_at < NOW() - INTERVAL '7 days';
--
-- C est strictement un cache d economie : si une entree est absente ou
-- perimee, on refait la requete. Pas de blocage si la table est vide.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.searxng_cache (
    query           TEXT PRIMARY KEY,
    results         JSONB NOT NULL,    -- liste de {url, title, snippet}
    n_results       INTEGER NOT NULL,
    fetched_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_searxng_cache_fetched ON news.searxng_cache (fetched_at);

-- ==============================================================================
-- Domain blacklist
--
-- Liste de domaines a exclure systematiquement des resultats, en particulier
-- pour la recherche libre (free_search) qui remonte beaucoup de bruit
-- (forums, marketplaces, sites etrangers sans rapport, etc.).
--
-- Les URLs de ces domaines sont filtrees DES le retour de SearXNG, avant
-- meme d atteindre le fetch. Ca economise du temps et des requetes.
--
-- Edition a chaud : INSERT/DELETE/UPDATE direct sur cette table, pas besoin
-- de rebuild de conteneur. L agent relit a chaque job (via LOAD_BLACKLIST()).
--
-- Le pattern est une simple correspondance de domaine (LIKE). Utile pour
-- bloquer toute une famille : ('xnxx.com') bloque forum.xnxx.com et www.xnxx.com.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.domain_blacklist (
    domain_pattern  TEXT PRIMARY KEY,       -- ex: 'xnxx.com', 'zhihu.com'
    reason          TEXT,                    -- documentation libre
    added_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_blacklist_pattern ON news.domain_blacklist (domain_pattern);

-- ==============================================================================
-- Extraction de candidats projets par URL (etape 4b)
--
-- Pour chaque URL utile du job, on produit un "candidat projet" issu soit de
-- la pre-extraction regex (method='regex'), soit du LLM cible (method='llm'),
-- soit directement des metadonnees internes MRAE (method='internal').
--
-- Le champ `status` permet de suivre le pipeline :
--   - not_relevant      : la page ne parle pas d'un projet ENR pour la zone
--   - extracted_direct  : regex ont trouve assez pour un candidat exploitable
--   - needs_llm         : pertinent mais incomplet, a repasser en 4b-2
--   - extracted_llm     : complete par le LLM apres needs_llm
--   - internal          : avis MRAE, metadonnees deja extraites
--   - skipped_no_text   : aucun texte a analyser (fetch echoue, PDF vide...)
--   - error             : exception inattendue lors de l extraction
--
-- L extraction est datee pour permettre un re-traitement si le prompt evolue.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.url_extractions (
    url             TEXT NOT NULL,
    job_id          UUID NOT NULL,
    status          TEXT NOT NULL,
    method          TEXT,              -- 'regex' | 'llm' | 'internal' | NULL
    is_enr_project  BOOLEAN,
    relevance_score FLOAT,             -- heuristique 0..1 (densite mots-cles, etc.)
    candidate       JSONB,             -- JSON du projet candidat extrait
    duration        FLOAT,
    error           TEXT,
    extracted_at    TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (url, job_id)
);

CREATE INDEX IF NOT EXISTS idx_extractions_job    ON news.url_extractions (job_id);
CREATE INDEX IF NOT EXISTS idx_extractions_status ON news.url_extractions (status);
CREATE INDEX IF NOT EXISTS idx_extractions_url    ON news.url_extractions (url);

-- ==============================================================================
-- Vue source_scores : agregation des feedbacks par contexte
-- Vue classique (pas materialisee) : les feedbacks sont pris en compte
-- immediatement, ce qui est le comportement voulu pour un systeme apprenant.
-- ==============================================================================
CREATE OR REPLACE VIEW news.source_scores AS
SELECT
    s.id              AS source_id,
    f.enr_type_code,
    f.region_name,
    f.dept_code,
    COUNT(f.id)       AS total,
    SUM(CASE WHEN f.is_hit THEN 1 ELSE 0 END) AS hits,
    AVG(f.quality_score) AS avg_quality,
    (SUM(CASE WHEN f.is_hit THEN 1 ELSE 0 END)::float
     / NULLIF(COUNT(f.id), 0))            AS hit_ratio
FROM news.sources s
LEFT JOIN news.source_feedback f ON s.id = f.source_id
GROUP BY s.id, f.enr_type_code, f.region_name, f.dept_code;

-- ==============================================================================
-- Index utiles
-- ==============================================================================
CREATE INDEX IF NOT EXISTS idx_sources_active
    ON news.sources(is_active);
CREATE INDEX IF NOT EXISTS idx_feedback_lookup
    ON news.source_feedback(source_id, enr_type_code);
CREATE INDEX IF NOT EXISTS idx_feedback_context
    ON news.source_feedback(enr_type_code, region_name);

-- ==============================================================================
-- Fonction get_best_sources : le coeur du scoring
--
-- Formule du score final :
--   score_empirique  = hit_ratio * avg_quality  (defaut 0.3 si inconnu)
--
--   final_score =   empirique           * 0.5
--                 + reliability_score   * 0.2
--                 + freshness_score     * 0.1
--                 + early_signal_score  * 0.1
--                 + affinity_score      * 0.1    (defaut 0.5 si inconnue)
--                 - cost_score          * 0.1    (penalite)
--                 + bonus_geographique
--                 + bonus_internal
--
-- Bonus geographique : +0.2 si couvre le dept exact,
--                      +0.1 si couvre la region,
--                      +0.05 si national
-- Bonus internal : +0.3 si source interne (ex: notre propre MRAE_DB)
-- ==============================================================================
CREATE OR REPLACE FUNCTION news.get_best_sources(
    p_enr_type TEXT,
    p_region   TEXT,
    p_dept     TEXT,
    p_limit    INT DEFAULT 20
)
RETURNS TABLE (
    source_id            INT,
    domain               TEXT,
    name                 TEXT,
    source_type          TEXT,
    signal_type          TEXT,
    is_internal          BOOLEAN,
    discovery_mode       TEXT,
    index_urls           TEXT[],
    hubs_discovered_at   TIMESTAMPTZ,
    niveau               TEXT,
    final_score          FLOAT
)
LANGUAGE sql STABLE AS $func$
    -- CTE best_coverage : pour chaque source, on ne garde QUE la couverture
    -- la plus specifique qui matche (dept exact > region > national).
    -- DISTINCT ON garantit une seule ligne par source_id -> pas de doublons.
    -- On LTRIM('0') les deux cotes pour que '018' matche '18' (l API envoie
    -- typiquement le code sur 3 caracteres alors qu en base on stocke '18').
    WITH best_coverage AS (
        SELECT DISTINCT ON (source_id)
            source_id,
            niveau,
            region_name,
            dept_code
        FROM news.source_coverage
        WHERE LTRIM(dept_code, '0') = LTRIM(p_dept, '0')
           OR region_name = p_region
           OR niveau      = 'national'
        ORDER BY
            source_id,
            CASE
                WHEN LTRIM(dept_code, '0') = LTRIM(p_dept, '0') THEN 3   -- plus specifique
                WHEN region_name = p_region THEN 2
                WHEN niveau      = 'national' THEN 1
                ELSE 0
            END DESC
    )
    SELECT
        s.id,
        s.domain,
        s.name,
        s.source_type,
        s.signal_type,
        s.is_internal,
        s.discovery_mode,
        s.index_urls,
        s.hubs_discovered_at,
        cov.niveau,
        (
              COALESCE(sc.hit_ratio * sc.avg_quality, 0.3) * 0.5
            + s.reliability_score                          * 0.2
            + s.freshness_score                            * 0.1
            + s.early_signal_score                         * 0.1
            + COALESCE(a.affinity_score, 0.5)              * 0.1
            - s.cost_score                                 * 0.1
            + CASE
                WHEN LTRIM(cov.dept_code, '0') = LTRIM(p_dept, '0') THEN 0.2
                WHEN cov.region_name = p_region THEN 0.1
                WHEN cov.niveau      = 'national' THEN 0.05
                ELSE 0
              END
            + CASE WHEN s.is_internal THEN 0.3 ELSE 0 END
        )::float AS final_score
    FROM news.sources s
    JOIN best_coverage cov ON cov.source_id = s.id
    LEFT JOIN news.source_scores sc
        ON sc.source_id     = s.id
       AND sc.enr_type_code = p_enr_type
       AND (sc.region_name  = p_region OR sc.region_name IS NULL)
    LEFT JOIN news.source_enr_affinity a
        ON a.source_id     = s.id
       AND a.enr_type_code = p_enr_type
    WHERE s.is_active = TRUE
    ORDER BY final_score DESC
    LIMIT p_limit;
$func$;

-- ==============================================================================
-- Fonction record_feedback : enregistre un retour d experience
--
-- Usage : appelee par l agent apres chaque tentative sur une source, qu elle
-- soit fructueuse ou non. Les champs debug (commune, search_query, url_found,
-- notes) permettent d expliquer a posteriori pourquoi telle source a ete
-- penalisee.
-- ==============================================================================
CREATE OR REPLACE FUNCTION news.record_feedback(
    p_source_id     INT,
    p_enr_type      TEXT,
    p_region        TEXT,
    p_dept          TEXT,
    p_commune       TEXT,
    p_search_query  TEXT,
    p_url_found     TEXT,
    p_is_hit        BOOLEAN,
    p_quality       FLOAT,
    p_notes         TEXT
)
RETURNS INT LANGUAGE plpgsql AS $func$
DECLARE
    v_id INT;
BEGIN
    INSERT INTO news.source_feedback (
        source_id, enr_type_code, region_name, dept_code, commune,
        search_query, url_found, is_hit, quality_score, notes
    )
    VALUES (
        p_source_id, p_enr_type, p_region, p_dept, p_commune,
        p_search_query, p_url_found, p_is_hit, p_quality, p_notes
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

-- ==============================================================================
-- Fonction get_internal_avis : avis MRAE existants matchant les communes cibles
--
-- Lit la table mrae.avis (gere par le MRAE Scraper) et retourne les avis
-- correspondant aux communes cibles et au type d'ENR recherche.
--
-- Matching combine pour robustesse :
--   - par NOM : a.communes && ARRAY[nom1, nom2, ...] (operateur d'intersection)
--   - par GEOMETRIE : ST_Contains(contour_commune, reproject(geom_point))
-- Une ligne est retenue si AU MOINS UN des deux criteres matche.
--
-- Filtres :
--   - a.type_projet         = p_enr_type
--   - TRIM(a.code_departement) = LTRIM dept (gere le padding CHAR(3))
--
-- Parametres :
--   p_insee_codes : liste des insee_com des communes cibles
--   p_enr_type    : type ENR recherche (ex 'photovoltaique')
--
-- Retour : un avis = une ligne, incluant le nom de la commune qui a matche
-- (utile pour l'affichage dans le resultat du job). Si l'avis matche plusieurs
-- communes cibles, c'est la premiere trouvee qui est retournee (DISTINCT ON).
-- ==============================================================================
CREATE OR REPLACE FUNCTION news.get_internal_avis(
    p_insee_codes TEXT[],
    p_enr_type    TEXT
)
RETURNS TABLE (
    r_avis_id           INT,
    r_reference_cle     TEXT,
    r_nom_projet        TEXT,
    r_date_avis         DATE,
    r_avis_type         TEXT,
    r_maitre_ouvrage    TEXT,
    r_puissance_mw      NUMERIC,
    r_superficie_ha     NUMERIC,
    r_location          TEXT,
    r_poste_connexion   TEXT,
    r_resume            TEXT,
    r_pdf_path          TEXT,
    r_matched_commune   TEXT
)
LANGUAGE sql STABLE AS $func$
    -- Les colonnes de sortie sont prefixees r_ pour eviter la collision avec
    -- les colonnes homonymes de mrae.avis dans le corps de la fonction
    -- (avis_type, nom_projet, location, resume sont notamment concernes).
    WITH targets AS (
        SELECT insee_com, nom, insee_dep, wkb_geometry
        FROM sig.communes
        WHERE insee_com = ANY(p_insee_codes)
    ),
    matches AS (
        SELECT DISTINCT ON (a.id)
            a.id                        AS r_avis_id,
            a.reference_cle::text       AS r_reference_cle,
            a.nom_projet::text          AS r_nom_projet,
            a.date_avis                 AS r_date_avis,
            a.avis_type::text           AS r_avis_type,
            a.maitre_ouvrage::text      AS r_maitre_ouvrage,
            a.puissance_mw::numeric     AS r_puissance_mw,
            a.superficie_ha::numeric    AS r_superficie_ha,
            a.location::text            AS r_location,
            a.poste_connexion::text     AS r_poste_connexion,
            a.resume::text              AS r_resume,
            a.pdf_path::text            AS r_pdf_path,
            t.nom::text                 AS r_matched_commune
        FROM mrae.avis a
        JOIN targets t ON
            TRIM(a.code_departement) = t.insee_dep::text
            AND (
                a.communes && ARRAY[t.nom::text]
                OR
                (a.geom_point IS NOT NULL
                 AND ST_Contains(t.wkb_geometry, ST_Transform(a.geom_point, 2154)))
            )
        WHERE a.type_projet = p_enr_type
        ORDER BY a.id, t.insee_com
    )
    SELECT * FROM matches
    ORDER BY r_date_avis DESC NULLS LAST, r_avis_id DESC;
$func$;

-- ==============================================================================
-- Fonction get_communes_in_radius : communes dans un rayon autour de l origine
--
-- Interroge la couche SIG partagee (sig.communes, importee separement).
--
-- Semantique : distance entre le CENTROIDE de la commune candidate et le
-- CONTOUR de la commune d origine. Plus lisible que contour-a-contour pour
-- les grandes communes (evite qu une dizaine de voisines limitrophes soient
-- toutes a distance 0). Une commune est retenue si son centroide est a moins
-- de p_radius_km km des bords de l origine.
--
-- Parametres :
--   p_commune_nom : nom exact tel que stocke dans sig.communes.nom
--   p_dept_code   : '34' ou '034' (LTRIM applique)
--   p_radius_km   : rayon en km, 10 par defaut
--
-- Retour : communes triees par distance croissante. La commune d origine
-- est identifiee par son INSEE (is_origin = TRUE uniquement pour elle).
-- ==============================================================================
CREATE OR REPLACE FUNCTION news.get_communes_in_radius(
    p_commune_nom TEXT,
    p_dept_code   TEXT,
    p_radius_km   INT DEFAULT 10
)
RETURNS TABLE (
    insee_com   TEXT,
    nom         TEXT,
    population  INTEGER,
    distance_m  FLOAT,
    is_origin   BOOLEAN
)
LANGUAGE sql STABLE AS $func$
    -- Semantique : on cherche les communes dont le CENTROIDE est dans un
    -- cercle de p_radius_km kilometres autour du CENTROIDE de la commune
    -- d origine. C est l interpretation la plus stricte (et la plus utile
    -- pour notre cas : Plumefinder fait ainsi). Une commune dont seule une
    -- pointe du contour entre dans la zone est exclue.
    --
    -- Ancienne semantique (relaxee, abandonnee) : ST_DWithin(centroide
    -- candidat, contour origine, R) : retournait toutes les communes
    -- limitrophes dont le contour touchait le tampon. Trop large.
    WITH origin AS (
        SELECT
            insee_com               AS insee,
            ST_Centroid(wkb_geometry) AS g_center
        FROM sig.communes
        WHERE LOWER(nom) = LOWER(p_commune_nom)
          AND insee_dep::text = LTRIM(p_dept_code, '0')
        LIMIT 1
    )
    SELECT
        c.insee_com,
        c.nom,
        c.population,
        ST_Distance(ST_Centroid(c.wkb_geometry), o.g_center)::float AS distance_m,
        (c.insee_com = o.insee) AS is_origin
    FROM sig.communes c, origin o
    WHERE ST_DWithin(ST_Centroid(c.wkb_geometry), o.g_center, p_radius_km * 1000)
    ORDER BY is_origin DESC, distance_m;
$func$;

-- ==============================================================================
-- SEED : sources initiales
-- Scores theoriques bases sur experience metier :
--   reliability : confiance globale
--   freshness   : frequence de mise a jour
--   early_signal: capacite a detecter tot
--   cost        : difficulte technique du scraping (0 = facile, 1 = dur)
-- ==============================================================================
INSERT INTO news.sources
    (domain, name, source_type, signal_type, is_structured, is_internal,
     reliability_score, freshness_score, early_signal_score, cost_score)
VALUES
    -- ==========================================================================
    -- Source interne prioritaire : notre propre base MRAE (table mrae.avis)
    -- ==========================================================================
    ('mrae.avis', 'MRAE_DB', 'officiel', 'reglementaire',
     TRUE, TRUE,
     1.00, 0.90, 1.00, 0.10),

    -- ==========================================================================
    -- Pseudo-source : recherche libre (sans site:) via SearXNG.
    -- Recoit les URLs trouvees en recherche ouverte (hors registre specifique).
    -- ==========================================================================
    ('*', 'Recherche libre', 'free_search', 'divers',
     FALSE, FALSE,
     0.60, 0.70, 0.60, 0.30),

    -- ==========================================================================
    -- Institutionnel national (signal amont : publication MRAe, bases officielles)
    -- ==========================================================================
    ('side.developpement-durable.gouv.fr', 'SIDE', 'officiel', 'reglementaire',
     TRUE, FALSE, 0.90, 0.55, 0.75, 0.30),
    ('geoportail-urbanisme.gouv.fr', 'Geoportail Urbanisme', 'open_data', 'reglementaire',
     TRUE, FALSE, 0.75, 0.40, 0.50, 0.50),

    -- ==========================================================================
    -- Annuaire ENR (national, tres exploitable, bon signal)
    -- ==========================================================================
    ('projet-renouvelable.fr', 'Projet Renouvelable', 'annuaire', 'reglementaire',
     TRUE, FALSE, 0.85, 0.85, 0.80, 0.25),

    -- ==========================================================================
    -- Plateformes d enquete publique (signal tres amont)
    -- ==========================================================================
    ('registre-dematerialise.fr', 'Registre Dematerialise', 'enquete_publique', 'enquete',
     TRUE, FALSE, 0.80, 0.80, 0.90, 0.45),
    ('enquete-publique.fr', 'Enquetes Publiques', 'enquete_publique', 'enquete',
     TRUE, FALSE, 0.75, 0.70, 0.85, 0.40),
    ('dematamp.fr', 'Dematamp', 'enquete_publique', 'enquete',
     TRUE, FALSE, 0.75, 0.70, 0.85, 0.40),

    -- ==========================================================================
    -- Comptes-rendus de conseils municipaux (deliberations sur projets ENR)
    -- politique.pappers.fr indexe et OCRise les CR de conseils communaux.
    -- Source secondaire mais utile pour reperer les projets en discussion
    -- amont (avant arretes prefectoraux). Plumefinder l utilise.
    -- ==========================================================================
    ('politique.pappers.fr', 'Pappers Politique', 'aggregateur', 'reglementaire',
     FALSE, FALSE, 0.70, 0.70, 0.80, 0.30),

    -- ==========================================================================
    -- Infrastructure reseau (plannings raccordement, S3REnR)
    -- ==========================================================================
    ('rte-france.com', 'RTE', 'infrastructure', 'technique',
     TRUE, FALSE, 0.85, 0.55, 0.75, 0.55),
    ('enedis.fr', 'Enedis', 'infrastructure', 'technique',
     TRUE, FALSE, 0.80, 0.55, 0.65, 0.50),

    -- ==========================================================================
    -- Open data (signal faible : souvent bruit SIREN)
    -- ==========================================================================
    ('data.gouv.fr', 'Data Gouv', 'open_data', 'open_data',
     TRUE, FALSE, 0.80, 0.60, 0.40, 0.30),

    -- ==========================================================================
    -- Presse specialisee (bons signaux, parfois paywall)
    -- ==========================================================================
    ('pv-magazine.fr', 'PV Magazine', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.85, 0.90, 0.70, 0.20),
    ('greenunivers.com', 'GreenUnivers', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.80, 0.85, 0.75, 0.20),
    ('connaissancedesenergies.org', 'Connaissance des Energies', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.75, 0.60, 0.50, 0.20),
    -- Presse specialisee ENR observee en sortie Plumefinder
    ('lagazettefrance.fr', 'La Gazette de France', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.70, 0.70, 0.65, 0.25),
    ('lendosphere.com', 'Lendosphere', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.75, 0.60, 0.85, 0.20),
    ('actu-environnement.com', 'Actu Environnement', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.85, 0.85, 0.75, 0.20),
    ('lemoniteur.fr', 'Le Moniteur', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.75, 0.75, 0.65, 0.25),
    ('enerzine.com', 'Enerzine', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.70, 0.80, 0.70, 0.20),
    ('revolution-energetique.com', 'Revolution Energetique', 'presse_specialisee', 'presse',
     FALSE, FALSE, 0.70, 0.75, 0.65, 0.20),

    -- ==========================================================================
    -- Presse locale (signal aval : apres decision)
    -- ==========================================================================
    ('midilibre.fr',     'Midi Libre',         'presse_locale', 'presse', FALSE, FALSE, 0.65, 0.80, 0.55, 0.25),
    ('ladepeche.fr',     'La Depeche',         'presse_locale', 'presse', FALSE, FALSE, 0.65, 0.80, 0.55, 0.25),
    ('sudouest.fr',      'Sud Ouest',          'presse_locale', 'presse', FALSE, FALSE, 0.65, 0.80, 0.55, 0.25),
    ('ouest-france.fr',  'Ouest France',       'presse_locale', 'presse', FALSE, FALSE, 0.65, 0.90, 0.55, 0.25),
    ('letelegramme.fr',  'Le Telegramme',      'presse_locale', 'presse', FALSE, FALSE, 0.65, 0.85, 0.55, 0.25),
    ('lamontagne.fr',    'La Montagne',        'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.70, 0.55, 0.25),
    ('leprogres.fr',     'Le Progres',         'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.70, 0.55, 0.25),
    ('ledauphine.com',   'Le Dauphine Libere', 'presse_locale', 'presse', FALSE, FALSE, 0.65, 0.80, 0.55, 0.25),
    ('estrepublicain.fr','Est Republicain',    'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.70, 0.55, 0.25),
    ('dna.fr',           'DNA',                'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.70, 0.55, 0.25),
    -- Presse regionale supplementaire (couverture par region a definir)
    ('lavoixdunord.fr',  'La Voix du Nord',    'presse_locale', 'presse', FALSE, FALSE, 0.70, 0.85, 0.60, 0.25),
    ('lanouvellerepublique.fr','Nouvelle Republique','presse_locale','presse',FALSE,FALSE,0.65,0.80,0.55,0.25),
    ('leberry.fr',       'Le Berry Republicain','presse_locale', 'presse', FALSE, FALSE, 0.60, 0.75, 0.55, 0.25),
    ('larepubliquedespyrenees.fr','Republique des Pyrenees','presse_locale','presse',FALSE,FALSE,0.60,0.75,0.55,0.25),
    ('laprovence.com',   'La Provence',        'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.75, 0.55, 0.25),
    ('nicematin.com',    'Nice Matin',         'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.75, 0.55, 0.25),
    ('varmatin.com',     'Var Matin',          'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.75, 0.55, 0.25),
    ('bienpublic.com',   'Le Bien Public',     'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.70, 0.55, 0.25),
    ('paris-normandie.fr','Paris Normandie',   'presse_locale', 'presse', FALSE, FALSE, 0.60, 0.70, 0.55, 0.25),

    -- ==========================================================================
    -- Sites developpeurs ENR (signal amont : projets en developpement)
    -- ==========================================================================
    ('jpee.fr',          'JP Energie Environnement','developpeur','developpeur',
     FALSE, FALSE, 0.70, 0.50, 0.85, 0.30),
    ('direction-france.totalenergies.fr', 'TotalEnergies France', 'developpeur', 'developpeur',
     FALSE, FALSE, 0.75, 0.55, 0.80, 0.30),
    ('engie-renouvelables.fr', 'Engie Renouvelables', 'developpeur', 'developpeur',
     FALSE, FALSE, 0.75, 0.55, 0.80, 0.30),
    ('edf-renouvelables.fr', 'EDF Renouvelables', 'developpeur', 'developpeur',
     FALSE, FALSE, 0.75, 0.55, 0.80, 0.30),
    ('voltalia.com',     'Voltalia',           'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('neoen.com',        'Neoen',              'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('boralex.com',      'Boralex',            'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('urbasolar.com',    'Urbasolar',          'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('tenergie.com',     'Tenergie',           'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('valeco.fr',        'Valeco',             'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('akuoenergy.com',   'Akuo Energy',        'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),
    ('qenergy.com',      'Q Energy',           'developpeur', 'developpeur',
     FALSE, FALSE, 0.70, 0.55, 0.80, 0.30),

    -- ==========================================================================
    -- Aggregateur communal (signal faible, bruit frequent)
    -- ==========================================================================
    ('files.appli-intramuros.com', 'Intramuros', 'aggregateur', 'presse',
     FALSE, FALSE, 0.55, 0.55, 0.40, 0.35),

    -- ==========================================================================
    -- 96 PREFECTURES DE METROPOLE (coverage strictement departementale)
    -- Source officielle des enquetes publiques, arretes prefectoraux,
    -- rapports commissaires-enqueteurs. Signal tres amont.
    -- ==========================================================================
    ('ain.gouv.fr', 'Prefecture Ain', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('aisne.gouv.fr', 'Prefecture Aisne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('allier.gouv.fr', 'Prefecture Allier', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('alpes-de-haute-provence.gouv.fr', 'Prefecture Alpes-de-Haute-Provence', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('hautes-alpes.gouv.fr', 'Prefecture Hautes-Alpes', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('alpes-maritimes.gouv.fr', 'Prefecture Alpes-Maritimes', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('ardeche.gouv.fr', 'Prefecture Ardeche', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('ardennes.gouv.fr', 'Prefecture Ardennes', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('ariege.gouv.fr', 'Prefecture Ariege', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('aube.gouv.fr', 'Prefecture Aube', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('aude.gouv.fr', 'Prefecture Aude', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('aveyron.gouv.fr', 'Prefecture Aveyron', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('bouches-du-rhone.gouv.fr', 'Prefecture Bouches-du-Rhone', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('calvados.gouv.fr', 'Prefecture Calvados', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('cantal.gouv.fr', 'Prefecture Cantal', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('charente.gouv.fr', 'Prefecture Charente', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('charente-maritime.gouv.fr', 'Prefecture Charente-Maritime', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('cher.gouv.fr', 'Prefecture Cher', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('correze.gouv.fr', 'Prefecture Correze', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('corse-du-sud.gouv.fr', 'Prefecture Corse-du-Sud', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-corse.gouv.fr', 'Prefecture Haute-Corse', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('cote-dor.gouv.fr', 'Prefecture Cote-d''Or', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('cotes-darmor.gouv.fr', 'Prefecture Cotes-d''Armor', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('creuse.gouv.fr', 'Prefecture Creuse', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('dordogne.gouv.fr', 'Prefecture Dordogne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('doubs.gouv.fr', 'Prefecture Doubs', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('drome.gouv.fr', 'Prefecture Drome', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('eure.gouv.fr', 'Prefecture Eure', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('eure-et-loir.gouv.fr', 'Prefecture Eure-et-Loir', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('finistere.gouv.fr', 'Prefecture Finistere', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('gard.gouv.fr', 'Prefecture Gard', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-garonne.gouv.fr', 'Prefecture Haute-Garonne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('gers.gouv.fr', 'Prefecture Gers', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('gironde.gouv.fr', 'Prefecture Gironde', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('herault.gouv.fr', 'Prefecture Herault', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('ille-et-vilaine.gouv.fr', 'Prefecture Ille-et-Vilaine', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('indre.gouv.fr', 'Prefecture Indre', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('indre-et-loire.gouv.fr', 'Prefecture Indre-et-Loire', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('isere.gouv.fr', 'Prefecture Isere', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('jura.gouv.fr', 'Prefecture Jura', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('landes.gouv.fr', 'Prefecture Landes', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('loir-et-cher.gouv.fr', 'Prefecture Loir-et-Cher', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('loire.gouv.fr', 'Prefecture Loire', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-loire.gouv.fr', 'Prefecture Haute-Loire', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('loire-atlantique.gouv.fr', 'Prefecture Loire-Atlantique', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('loiret.gouv.fr', 'Prefecture Loiret', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('lot.gouv.fr', 'Prefecture Lot', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('lot-et-garonne.gouv.fr', 'Prefecture Lot-et-Garonne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('lozere.gouv.fr', 'Prefecture Lozere', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('maine-et-loire.gouv.fr', 'Prefecture Maine-et-Loire', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('manche.gouv.fr', 'Prefecture Manche', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('marne.gouv.fr', 'Prefecture Marne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-marne.gouv.fr', 'Prefecture Haute-Marne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('mayenne.gouv.fr', 'Prefecture Mayenne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('meurthe-et-moselle.gouv.fr', 'Prefecture Meurthe-et-Moselle', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('meuse.gouv.fr', 'Prefecture Meuse', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('morbihan.gouv.fr', 'Prefecture Morbihan', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('moselle.gouv.fr', 'Prefecture Moselle', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('nievre.gouv.fr', 'Prefecture Nievre', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('nord.gouv.fr', 'Prefecture Nord', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('oise.gouv.fr', 'Prefecture Oise', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('orne.gouv.fr', 'Prefecture Orne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('pas-de-calais.gouv.fr', 'Prefecture Pas-de-Calais', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('puy-de-dome.gouv.fr', 'Prefecture Puy-de-Dome', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('pyrenees-atlantiques.gouv.fr', 'Prefecture Pyrenees-Atlantiques', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('hautes-pyrenees.gouv.fr', 'Prefecture Hautes-Pyrenees', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('pyrenees-orientales.gouv.fr', 'Prefecture Pyrenees-Orientales', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('bas-rhin.gouv.fr', 'Prefecture Bas-Rhin', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haut-rhin.gouv.fr', 'Prefecture Haut-Rhin', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('rhone.gouv.fr', 'Prefecture Rhone', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-saone.gouv.fr', 'Prefecture Haute-Saone', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('saone-et-loire.gouv.fr', 'Prefecture Saone-et-Loire', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('sarthe.gouv.fr', 'Prefecture Sarthe', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('savoie.gouv.fr', 'Prefecture Savoie', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-savoie.gouv.fr', 'Prefecture Haute-Savoie', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('paris.gouv.fr', 'Prefecture Paris', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('seine-maritime.gouv.fr', 'Prefecture Seine-Maritime', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('seine-et-marne.gouv.fr', 'Prefecture Seine-et-Marne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('yvelines.gouv.fr', 'Prefecture Yvelines', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('deux-sevres.gouv.fr', 'Prefecture Deux-Sevres', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('somme.gouv.fr', 'Prefecture Somme', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('tarn.gouv.fr', 'Prefecture Tarn', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('tarn-et-garonne.gouv.fr', 'Prefecture Tarn-et-Garonne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('var.gouv.fr', 'Prefecture Var', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('vaucluse.gouv.fr', 'Prefecture Vaucluse', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('vendee.gouv.fr', 'Prefecture Vendee', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('vienne.gouv.fr', 'Prefecture Vienne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('haute-vienne.gouv.fr', 'Prefecture Haute-Vienne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('vosges.gouv.fr', 'Prefecture Vosges', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('yonne.gouv.fr', 'Prefecture Yonne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('territoire-de-belfort.gouv.fr', 'Prefecture Territoire de Belfort', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('essonne.gouv.fr', 'Prefecture Essonne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('hauts-de-seine.gouv.fr', 'Prefecture Hauts-de-Seine', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('seine-saint-denis.gouv.fr', 'Prefecture Seine-Saint-Denis', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('val-de-marne.gouv.fr', 'Prefecture Val-de-Marne', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40),
    ('val-doise.gouv.fr', 'Prefecture Val-d''Oise', 'prefecture', 'reglementaire',
     TRUE, FALSE, 0.95, 0.75, 0.95, 0.40)
ON CONFLICT (domain) DO NOTHING;

-- ==============================================================================
-- COVERAGE DEPARTEMENTALE DES 96 PREFECTURES
-- Une prefecture ne remonte QUE pour son departement.
-- ==============================================================================
INSERT INTO news.source_coverage (source_id, niveau, region_name, dept_code)
SELECT s.id, 'departemental', NULL, d.dept_code
FROM news.sources s
JOIN (VALUES
    ('ain.gouv.fr', '01'),
    ('aisne.gouv.fr', '02'),
    ('allier.gouv.fr', '03'),
    ('alpes-de-haute-provence.gouv.fr', '04'),
    ('hautes-alpes.gouv.fr', '05'),
    ('alpes-maritimes.gouv.fr', '06'),
    ('ardeche.gouv.fr', '07'),
    ('ardennes.gouv.fr', '08'),
    ('ariege.gouv.fr', '09'),
    ('aube.gouv.fr', '10'),
    ('aude.gouv.fr', '11'),
    ('aveyron.gouv.fr', '12'),
    ('bouches-du-rhone.gouv.fr', '13'),
    ('calvados.gouv.fr', '14'),
    ('cantal.gouv.fr', '15'),
    ('charente.gouv.fr', '16'),
    ('charente-maritime.gouv.fr', '17'),
    ('cher.gouv.fr', '18'),
    ('correze.gouv.fr', '19'),
    ('corse-du-sud.gouv.fr', '2A'),
    ('haute-corse.gouv.fr', '2B'),
    ('cote-dor.gouv.fr', '21'),
    ('cotes-darmor.gouv.fr', '22'),
    ('creuse.gouv.fr', '23'),
    ('dordogne.gouv.fr', '24'),
    ('doubs.gouv.fr', '25'),
    ('drome.gouv.fr', '26'),
    ('eure.gouv.fr', '27'),
    ('eure-et-loir.gouv.fr', '28'),
    ('finistere.gouv.fr', '29'),
    ('gard.gouv.fr', '30'),
    ('haute-garonne.gouv.fr', '31'),
    ('gers.gouv.fr', '32'),
    ('gironde.gouv.fr', '33'),
    ('herault.gouv.fr', '34'),
    ('ille-et-vilaine.gouv.fr', '35'),
    ('indre.gouv.fr', '36'),
    ('indre-et-loire.gouv.fr', '37'),
    ('isere.gouv.fr', '38'),
    ('jura.gouv.fr', '39'),
    ('landes.gouv.fr', '40'),
    ('loir-et-cher.gouv.fr', '41'),
    ('loire.gouv.fr', '42'),
    ('haute-loire.gouv.fr', '43'),
    ('loire-atlantique.gouv.fr', '44'),
    ('loiret.gouv.fr', '45'),
    ('lot.gouv.fr', '46'),
    ('lot-et-garonne.gouv.fr', '47'),
    ('lozere.gouv.fr', '48'),
    ('maine-et-loire.gouv.fr', '49'),
    ('manche.gouv.fr', '50'),
    ('marne.gouv.fr', '51'),
    ('haute-marne.gouv.fr', '52'),
    ('mayenne.gouv.fr', '53'),
    ('meurthe-et-moselle.gouv.fr', '54'),
    ('meuse.gouv.fr', '55'),
    ('morbihan.gouv.fr', '56'),
    ('moselle.gouv.fr', '57'),
    ('nievre.gouv.fr', '58'),
    ('nord.gouv.fr', '59'),
    ('oise.gouv.fr', '60'),
    ('orne.gouv.fr', '61'),
    ('pas-de-calais.gouv.fr', '62'),
    ('puy-de-dome.gouv.fr', '63'),
    ('pyrenees-atlantiques.gouv.fr', '64'),
    ('hautes-pyrenees.gouv.fr', '65'),
    ('pyrenees-orientales.gouv.fr', '66'),
    ('bas-rhin.gouv.fr', '67'),
    ('haut-rhin.gouv.fr', '68'),
    ('rhone.gouv.fr', '69'),
    ('haute-saone.gouv.fr', '70'),
    ('saone-et-loire.gouv.fr', '71'),
    ('sarthe.gouv.fr', '72'),
    ('savoie.gouv.fr', '73'),
    ('haute-savoie.gouv.fr', '74'),
    ('paris.gouv.fr', '75'),
    ('seine-maritime.gouv.fr', '76'),
    ('seine-et-marne.gouv.fr', '77'),
    ('yvelines.gouv.fr', '78'),
    ('deux-sevres.gouv.fr', '79'),
    ('somme.gouv.fr', '80'),
    ('tarn.gouv.fr', '81'),
    ('tarn-et-garonne.gouv.fr', '82'),
    ('var.gouv.fr', '83'),
    ('vaucluse.gouv.fr', '84'),
    ('vendee.gouv.fr', '85'),
    ('vienne.gouv.fr', '86'),
    ('haute-vienne.gouv.fr', '87'),
    ('vosges.gouv.fr', '88'),
    ('yonne.gouv.fr', '89'),
    ('territoire-de-belfort.gouv.fr', '90'),
    ('essonne.gouv.fr', '91'),
    ('hauts-de-seine.gouv.fr', '92'),
    ('seine-saint-denis.gouv.fr', '93'),
    ('val-de-marne.gouv.fr', '94'),
    ('val-doise.gouv.fr', '95')
) AS d(domain, dept_code) ON s.domain = d.domain
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- SEED : couverture geographique
-- ==============================================================================

-- National : officiel, enquete, infrastructure, open_data, presse specialisee,
-- annuaire, free_search, aggregateur. Les prefectures ont leur coverage
-- strictement departementale (voir plus bas).
INSERT INTO news.source_coverage (source_id, niveau)
SELECT id, 'national'
FROM news.sources
WHERE source_type IN ('officiel', 'enquete_publique', 'infrastructure',
                      'open_data', 'presse_specialisee', 'aggregateur',
                      'annuaire', 'free_search', 'developpeur')
ON CONFLICT DO NOTHING;

-- Regional : presse locale, avec la ou les regions couvertes
INSERT INTO news.source_coverage (source_id, niveau, region_name)
SELECT s.id, 'regional', r.region
FROM news.sources s
JOIN (VALUES
    ('midilibre.fr',     'Occitanie'),
    ('ladepeche.fr',     'Occitanie'),
    ('sudouest.fr',      'Nouvelle-Aquitaine'),
    ('ouest-france.fr',  'Bretagne'),
    ('ouest-france.fr',  'Pays de la Loire'),
    ('ouest-france.fr',  'Normandie'),
    ('letelegramme.fr',  'Bretagne'),
    ('letelegramme.fr',  'Pays de la Loire'),
    ('lamontagne.fr',    'Auvergne-Rhone-Alpes'),
    ('leprogres.fr',     'Auvergne-Rhone-Alpes'),
    ('ledauphine.com',   'Auvergne-Rhone-Alpes'),
    ('ledauphine.com',   'Provence-Alpes-Cote d''Azur'),
    ('estrepublicain.fr','Grand Est'),
    ('estrepublicain.fr','Bourgogne-Franche-Comte'),
    ('dna.fr',           'Grand Est'),
    -- Ajouts du livraison "tout integrer"
    ('lavoixdunord.fr',  'Hauts-de-France'),
    ('lanouvellerepublique.fr', 'Centre-Val de Loire'),
    ('lanouvellerepublique.fr', 'Nouvelle-Aquitaine'),
    ('leberry.fr',       'Centre-Val de Loire'),
    ('larepubliquedespyrenees.fr', 'Nouvelle-Aquitaine'),
    ('laprovence.com',   'Provence-Alpes-Cote d''Azur'),
    ('nicematin.com',    'Provence-Alpes-Cote d''Azur'),
    ('varmatin.com',     'Provence-Alpes-Cote d''Azur'),
    ('bienpublic.com',   'Bourgogne-Franche-Comte'),
    ('paris-normandie.fr', 'Normandie')
) AS r(domain, region) ON s.domain = r.domain
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- SEED : affinite source <-> type ENR
-- ==============================================================================

-- Photovoltaique : presse + officiel + specialise (pv-magazine en particulier)
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'photovoltaique', 0.80
FROM news.sources
WHERE source_type IN ('presse_locale', 'presse_specialisee', 'officiel', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- pv-magazine : boost specifique PV
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'photovoltaique', 0.95
FROM news.sources
WHERE domain = 'pv-magazine.fr'
ON CONFLICT (source_id, enr_type_code) DO UPDATE
    SET affinity_score = EXCLUDED.affinity_score;

-- Agrivoltaique : meme sources que PV + officiel
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'agrivoltaique', 0.75
FROM news.sources
WHERE source_type IN ('presse_locale', 'presse_specialisee', 'officiel', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- Eolien : fort signal reglementaire (recours frequents)
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'eolien', 0.90
FROM news.sources
WHERE source_type IN ('officiel', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- Eolien : presse locale aussi (opposition locale frequente)
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'eolien', 0.80
FROM news.sources
WHERE source_type = 'presse_locale'
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- Poste electrique : RTE et Enedis en priorite
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'poste', 0.95
FROM news.sources
WHERE domain IN ('rte-france.com', 'enedis.fr')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- Stockage : officiel et presse specialisee
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'stockage', 0.70
FROM news.sources
WHERE source_type IN ('officiel', 'presse_specialisee', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- Developpeurs : forte affinite a tous les types ENR (par essence)
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT s.id, t.code, 0.85
FROM news.sources s
CROSS JOIN news.enr_types t
WHERE s.source_type = 'developpeur'
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- ==============================================================================
-- SEED : blacklist de domaines (bruit recurrent observe sur les recherches libres)
-- ==============================================================================
INSERT INTO news.domain_blacklist (domain_pattern, reason) VALUES
    -- Forums / reseaux sociaux sans rapport
    ('zhihu.com',       'Forum chinois sans rapport avec ENR France'),
    ('xnxx.com',        'Site pornographique'),
    ('pornhub.com',     'Site pornographique'),
    ('quora.com',       'Forum generaliste'),
    ('reddit.com',      'Forum generaliste (bruit frequent)'),
    ('baidu.com',       'Moteur de recherche chinois'),
    ('fwxgx.com',       'Site chinois non pertinent'),
    -- Marketplaces / tourisme / commerce
    ('tripadvisor.fr',  'Tourisme'),
    ('tripadvisor.es',  'Tourisme'),
    ('tripadvisor.com', 'Tourisme'),
    ('booking.com',     'Tourisme'),
    ('airbnb.fr',       'Tourisme'),
    ('mappy.com',       'Cartographie commerciale'),
    ('amazon.fr',       'E-commerce'),
    ('ebay.fr',         'E-commerce'),
    ('leboncoin.fr',    'Petites annonces'),
    ('tefal.fr',        'Marque de produits electromenagers'),
    -- Aggregateurs sans valeur ajoutee specifique
    ('pinterest.fr',    'Aggregateur images'),
    ('pinterest.com',   'Aggregateur images'),
    ('wikiusa.org',     'Faux wiki'),
    -- Sites d annuaire d entreprises (valeur marginale, bruit fort)
    ('annuaire-entreprises.data.gouv.fr', 'Annuaire SIRENE, bruit frequent'),
    ('pappers.fr',                        'Annuaire entreprises (sauf justice.pappers.fr)'),
    ('societe.com',                       'Annuaire entreprises'),
    ('infogreffe.fr',                     'Annuaire entreprises')
ON CONFLICT (domain_pattern) DO NOTHING;

-- ==============================================================================
-- DISCOVERY MODE : bascule TOUTES les prefectures en 'crawl_index'
--
-- Les prefectures publient leurs enquetes publiques sur PLUSIEURS pages d index
-- thematiques (Rapport-Enquetes-publiques, AOEP, Participation-du-public,
-- Etudes-prealables-agricoles, etc.) dont l arborescence varie d un site a
-- l autre. Plutot que de hardcoder ces paths, on s appuie sur :
--
-- 1) Un import initial des hubs decouverts par tools/discover_hubs.py
--    (script de scraping qui interroge le moteur de recherche interne de
--    chaque prefecture sur les termes ENR et collecte les pages parents
--    pertinentes). Voir l'UPDATE ci-dessous (91 prefectures, 941 hubs).
--
-- 2) Un mecanisme 'lazy refresh' cote agent : si une prefecture a un
--    hubs_discovered_at trop ancien (TTL configurable, defaut 30j), on
--    relance discover_hubs(domain) avant le crawl pour ce job.
--
-- Les 5 prefectures absentes de l import initial (Essonne, Paris, Rhone,
-- Seine-Saint-Denis, Val-d'Oise) auront hubs_discovered_at=NULL et leur
-- decouverte sera declenchee au premier job qui les concerne.
-- ==============================================================================
UPDATE news.sources SET discovery_mode = 'crawl_index'
WHERE source_type = 'prefecture';

-- ==============================================================================
-- IMPORT INITIAL DES HUBS PREFECTORAUX (91 prefectures, 941 hubs)
--
-- Decouverts automatiquement par tools/discover_hubs.py (cf. ce script).
-- Ces hubs serviront de point de depart pour le crawl_index. Ils seront
-- rafraichis au cas par cas par la decouverte 'lazy' (TTL 30j) :
-- quand un job touche une prefecture dont hubs_discovered_at est trop ancien,
-- _ensure_hubs_fresh() relance discover_hubs(domain) avant le crawl.
--
-- 5 prefectures sont absentes de ce seed initial (Essonne, Paris, Rhone,
-- Seine-Saint-Denis, Val-d'Oise) : leur hubs_discovered_at reste NULL et
-- la decouverte sera declenchee au premier job qui les concerne.
-- ==============================================================================
UPDATE news.sources s SET
    discovery_mode      = 'crawl_index',
    index_urls          = h.urls,
    hubs_discovered_at  = NOW()
FROM (VALUES
    ('ain.gouv.fr', ARRAY['https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Autorisations-d-urbanisme/Projets-photovoltaiques', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Construire-et-renover', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transitions-energetique-et-ecologique/Accompagnement-dans-la-transition', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transitions-energetique-et-ecologique/Developpement-des-energies-renouvelables', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Urbanisme-et-amenagement-durables/Preservation-du-foncier/Commission-departementale-de-preservation-des-espaces-naturels.-agricoles-et-forestiers-CDPENAF', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Conference-environnementale', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees/Preuves-de-depots', 'https://www.ain.gouv.fr/Publications/Enquetes-publiques/Installations-classees-pour-l-environnement', 'https://www.ain.gouv.fr/Publications/Enquetes-publiques/Projets-photovoltaiques', 'https://www.ain.gouv.fr/Publications/Enquetes-publiques/Urbanisme']),
    ('aisne.gouv.fr', ARRAY['https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Consultations-publiques/Energie/Document-cadre-photovoltaique', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Consultations-publiques/ICPE', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Enquetes-publiques/ICPE', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Enquetes-publiques/Urbanisme', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Avis-de-l-autorite-environnementale/Avis-de-l-AE/ICPE', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Police-de-l-Eau/Declarations-au-titre-de-la-loi-sur-l-eau', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Energies-et-transition-ecologique', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Arretes-de-mesures-de-police-administrative', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-environnementale/Dossiers-d-enquete-publique', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-environnementale/Dossiers-de-consultation-du-public-dite-parallelisee', 'https://www.aisne.gouv.fr/Publications/Espace-presse/Communiques-et-dossiers-de-presse-2020', 'https://www.aisne.gouv.fr/Publications/Espace-presse/Communiques-et-dossiers-de-presse-2021']),
    ('allier.gouv.fr', ARRAY['https://www.allier.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foncier-agricole-CDPENAF/Compensation-agricole-projets-d-amenagement', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foncier-agricole-CDPENAF/Document-cadre-relatif-aux-installations-photovoltaiques', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction/Atlas-departemental/Energie', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction/Comment-amenager-durablement', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Environnement/Eau-et-milieux-aquatiques', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees/Dossiers-d-examen-au-cas-par-cas', 'https://www.allier.gouv.fr/Publications/Enquetes-et-consultations-publiques/Consultations-publiques-achevees/Centrales-photovoltaiques', 'https://www.allier.gouv.fr/Publications/Enquetes-et-consultations-publiques/Consultations-publiques-achevees/Eoliennes', 'https://www.allier.gouv.fr/Publications/Enquetes-et-consultations-publiques/Consultations-publiques-en-cours']),
    ('alpes-de-haute-provence.gouv.fr', ARRAY['https://www.alpes-de-haute-provence.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement/Compensation-agricole/Etudes-prealables', 'https://www.alpes-de-haute-provence.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement/Energies-renouvelables', 'https://www.alpes-de-haute-provence.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Eau-et-milieux-aquatiques/Actes-administratifs-delivres', 'https://www.alpes-de-haute-provence.gouv.fr/Publications/Appels-a-projets-Consultations/Enquetes-publiques-autorisations-et-avis/Listes-des-communes-par-ordre-alphabetique', 'https://www.alpes-de-haute-provence.gouv.fr/Publications/Appels-a-projets-Consultations/Participation-du-public-environnement/Document-cadre-04-PV-sol/Consultation-en-cours', 'https://www.alpes-de-haute-provence.gouv.fr/Publications/Publications-administratives-et-legales/Recueil-des-Actes-Administratifs']),
    ('alpes-maritimes.gouv.fr', ARRAY['https://www.alpes-maritimes.gouv.fr/Publications/Enquetes-publiques/Autorisation-de-defrichement']),
    ('ardeche.gouv.fr', ARRAY['https://www.ardeche.gouv.fr/Actions-de-l-Etat/Agriculture/Foncier/Urbanisme-en-zone-agricole', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Avis-de-l-autorite-environnementale', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-Refus/SAS-Parc-eolien-de-Pratauberat', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-de-prescriptions-complementaires', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-de-prescriptions-speciales', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-modificatif', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Enquetes-publiques-procedure-d-autorisation/Enquetes-publiques-terminees', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Procedure-de-declaration/Preuve-de-depot', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Transition-energetique/Le-developpement-de-l-eolien/L-eolien-pourquoi-et-comment', 'https://www.ardeche.gouv.fr/Pied-de-page/Enquetes-et-consultations-publiques-hors-ICPE/Enquetes-et-consultations-en-cours', 'https://www.ardeche.gouv.fr/Publications/Enquetes-et-consultations-publiques-hors-ICPE/Consultations-publiques/En-cours', 'https://www.ardeche.gouv.fr/Publications/Enquetes-et-consultations-publiques-hors-ICPE/Enquetes-publiques/En-cours', 'https://www.ardeche.gouv.fr/Publications/Enquetes-et-consultations-publiques-hors-ICPE/Enquetes-publiques/Terminees']),
    ('ardennes.gouv.fr', ARRAY['https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Energie-Climat/Les-energies-renouvelables/Le-plan-de-paysage-eolien', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Energie-Climat/Les-energies-renouvelables/Le-pole-Energies-renouvelables-des-Ardennes', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Enquetes-publiques-et-consultations-du-public/Hors-ICPE-loi-sur-l-eau.-urbanisme', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Enquetes-publiques-et-consultations-du-public/Pour-les-ICPE', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees-pour-la-protection-de-l-environnement-ICPE/Cas-par-Cas']),
    ('ariege.gouv.fr', ARRAY['https://www.ariege.gouv.fr/Actions-de-l-Etat/Agriculture/Compensation-collective-agricole', 'https://www.ariege.gouv.fr/Actions-de-l-Etat/Environnement-biodiversite/Installations-classees-Mines-Carrieres/Arretes-prefectoraux-d-autorisation-et-complementaires', 'https://www.ariege.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique/Favoriser-le-developpement-des-energies-renouvelables', 'https://www.ariege.gouv.fr/Publications/Consultations-du-public/Consultations-du-public-direction-departementale-des-territoires/Urbanisme-ADS', 'https://www.ariege.gouv.fr/Publications/Enquetes-publiques/EOLIEN', 'https://www.ariege.gouv.fr/Publications/Enquetes-publiques/URBANISME', 'https://www.ariege.gouv.fr/Publications/Espace-presse/Communiques-de-presse/Tournee-de-prevention-Bon-ete-bons-reflexes-sante']),
    ('aube.gouv.fr', ARRAY['https://www.aube.gouv.fr/Publications/Amenagement-du-territoire-Environnement-Developpement-durable/ICPE-Installations-Classees-pour-la-Protection-de-l-Environnement/Publications-reglementaires-arretes-ICPE-preuves-de-depot-mises-en-demeure-et-sanctions/Installations-classees-arretes-d-enregistrement', 'https://www.aube.gouv.fr/Publications/Amenagement-du-territoire-Environnement-Developpement-durable/ICPE-Installations-Classees-pour-la-Protection-de-l-Environnement/Publications-reglementaires-arretes-ICPE-preuves-de-depot-mises-en-demeure-et-sanctions/Installations-classees-autorisations-uniques-et-environnementales', 'https://www.aube.gouv.fr/Publications/Consultations-du-public-declarations-d-intention-et-commissaire-enqueteur/Consultations-du-public-organisees-par-l-Etat/SAINT-OULPH-et-ETRELLES-s-AUBE-Societe-SAINT-OULPH-ETRELLES-ENERGIE-Projet-de-parc-eolien', 'https://www.aube.gouv.fr/Publications/Consultations-du-public-declarations-d-intention-et-commissaire-enqueteur/Rapports-et-conclusions-des-commissaires-enqueteurs']),
    ('aude.gouv.fr', ARRAY['https://entreprendre.service-public.fr/vosdroits', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2017-2019', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2020', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2021', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2022', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2023/avril-mai-juin', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2023/janvier-fevrier-mars', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2023/septembre-octobre-novembre-decembre', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2024/Avril-Mai-Juin-Juillet', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2024/Janvier-Fevrier-Mars', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2024/Septembre-Octobre-Novembre-Decembre', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2025/Avril-Mai-Juin', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2025/Janvier-Fevrier-Mars', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2025/Juillet-Aout-Septembre', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Eau/Autorisations-Loi-sur-l-Eau', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Eau/Declarations-Loi-sur-l-Eau/2023/Recepisses', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Eau/Declarations-Loi-sur-l-Eau/2024/Recepisses', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Eau/Declarations-Loi-sur-l-Eau/2025/Recepisses', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Eau/Declarations-Loi-sur-l-Eau/2026/Arretes-prefectoraux', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Environnement-et-Developpement-durable/Energies-Renouvelables/La-planification-des-energies-renouvelables', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Eoliennes-flottantes/Projets-de-fermes-pilotes/Projet-EFGL-Eoliennes-Flottantes-du-Golfe-du-Lion', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Eoliennes-flottantes/Projets-de-fermes-pilotes/Projet-EolMed', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Arretes-prefectoraux-d-autorisation-arretes-complementaires', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Consultation-parallelisee', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Les-dossiers-ICPE-complets-a-consulter/Les-Parcs-Eoliens', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Parcs-eoliens-dans-l-Aude', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Preuve-de-depot-de-la-declaration/Annee-2024', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Preuve-de-depot-de-la-declaration/Annee-2025', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Preuve-de-depot-de-la-declaration/Annee-2026', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Les-enquetes-publiques-et-consultations-du-public-dossiers-complets-hors-ICPE/Enquetes-diverses', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Les-enquetes-publiques-et-consultations-du-public-dossiers-complets-hors-ICPE/Photovoltaique']),
    ('aveyron.gouv.fr', ARRAY['https://www.aveyron.gouv.fr/Actions-de-l-Etat/Agriculture-et-foret/Foncier/Baux-ruraux', 'https://www.aveyron.gouv.fr/Actions-de-l-Etat/Agriculture-et-foret/Foncier/Compensation-Agricole-Collective', 'https://www.aveyron.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique/Developpement-des-energies-renouvelables', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Consultations/Consultations-en-cours', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Enquetes-publiques/Cloturees/Autres-enquetes', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Enquetes-publiques/Cloturees/Installation-Classee-Pour-la-Protection-de-l-Environnement-ICPE', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Enquetes-publiques/EN-COURS', 'https://www.aveyron.gouv.fr/Publications/Decisions-administratives/ICPE/Arretes-prefectoraux', 'https://www.aveyron.gouv.fr/Publications/Decisions-administratives/ICPE/Preuves-de-depot-des-declarations', 'https://www.aveyron.gouv.fr/Publications/Decisions-administratives/Loi-sur-l-eau/Recepisses']),
    ('bas-rhin.gouv.fr', ARRAY['https://www.bas-rhin.gouv.fr/Actions-de-l-Etat/Environnement/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Liste-des-ICPE-soumises-a-autorisation', 'https://www.bas-rhin.gouv.fr/Actions-de-l-Etat/Environnement/Photovoltaique', 'https://www.bas-rhin.gouv.fr/Publications/Consultations-du-public']),
    ('bouches-du-rhone.gouv.fr', ARRAY['https://www.bouches-du-rhone.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foret/Defrichement/PPVE/2020-a-2015', 'https://www.bouches-du-rhone.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Preservation-des-espaces-agricoles-naturels-et-forestiers/Compensation-collective-agricole', 'https://www.bouches-du-rhone.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Transition-energetique-energies-renouvelables', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Eau/Arretes-de-l-eau', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Eau/Les-recepisses-de-l-eau', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Enquetes-publiques-hors-ICPE', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Installations-Classees-soumises-a-autorisation-et-a-enregistrement-Carrieres-et-Geothermie', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Installations-Classees-soumises-a-declaration', 'https://www.bouches-du-rhone.gouv.fr/Services-de-l-Etat/Prefecture-et-sous-prefectures']),
    ('calvados.gouv.fr', ARRAY['https://www.calvados.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction.-logement/Energies-renouvelables/Eolien', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Culture-Patrimoine/Promotion-de-la-qualite-architecturale.-paysagere-et-urbaine', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Avis-de-l-Autorite-Environnementale', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Energies-renouvelables/Eolien-en-mer', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Demarches-declaration.-enregistrement.-autorisation/Procedure-d-installation-d-un-parc-eolien-terrestre', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/ARRETES-PREFECTORAUX-2021', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/ARRETES-PREFECTORAUX-2022', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/ARRETES-PREFECTORAUX-2023', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/ARRETES-PREFECTORAUX-2024', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/Arretes-prefectoraux-2025', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/Arretes-prefectoraux-2026', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Enquete-publique-consultation-du-public-par-voie-electronique/2021/SAS-eoliennes-du-Pays-d-Auge-Norrey-en-Auge-et-Barou-en-Auge', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Enquete-publique-consultation-du-public-par-voie-electronique/2022/Enquete-publique-SEPE-GINKO-Valambray', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Enquete-publique-consultation-du-public-par-voie-electronique/2024', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Mer.-littoral-et-securite-maritime/Domaine-public-maritime', 'https://www.calvados.gouv.fr/Publications/Avis-et-consultation-du-public/Avis-enquete-publique/Avis-d-enquete-publique', 'https://www.calvados.gouv.fr/Publications/Avis-et-consultation-du-public/Avis-enquete-publique/Les-avis-d-enquetes-publiques-en-cours', 'https://www.calvados.gouv.fr/Publications/Avis-et-consultation-du-public/Consultation-du-public/Conclusions-Consultation-du-public/conclusion-enquete-publique-projet-de-raccordement-Centre-Manche-1', 'https://www.calvados.gouv.fr/Publications/Avis-et-consultation-du-public/Consultation-du-public/Les-consultations-en-cours']),
    ('cantal.gouv.fr', ARRAY['https://www.cantal.gouv.fr/Action-de-l-Etat/Amenagement-du-Territoire-Construction/Transition-energetique-et-developpement-durable', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Biodiversite-et-milieux-naturels/Les-especes-protegees/Les-oiseaux', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Energies-renouvelables/Les-parcs-eoliens', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Information-et-participation-du-public/Participation-du-public/Consultations', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Information-et-participation-du-public/Participation-du-public/Consultations-terminees', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Information-et-participation-du-public/Publications-relatives-aux-procedures-environnementales/Annee-2021', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Information-et-participation-du-public/Publications-relatives-aux-procedures-environnementales/Annee-2022', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Decisions-individuelles', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Generalites-reclamations', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Preuves-de-depot/ANNEE-2023', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Preuves-de-depot/ANNEE-2024', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Preuves-de-depot/ANNEE-2025']),
    ('charente-maritime.gouv.fr', ARRAY['https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Agriculture/Agriculture-urbanisme-et-territoire', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-et-commissions-consultatives/Consultations-du-public/Consultations-parallelisees-en-cours-loi-industrie-verte', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-et-commissions-consultatives/Consultations-du-public/Enquetes-publiques-cloturees', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-et-commissions-consultatives/Consultations-du-public/Enquetes-publiques-en-cours', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Eau-et-milieux-aquatiques/Dossiers-loi-sur-l-eau', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Examen-au-cas-par-cas/Projets-Examen-au-cas-par-cas-et-decision', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Installation-Classee-pour-la-Protection-de-l-Environnement', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Projet-eolien-en-mer']),
    ('charente.gouv.fr', ARRAY['https://www.charente.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-espaces-naturels/Preservation-des-espaces-naturels-agricoles-et-forestiers-ENAF', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Amberac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Ambernac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Baignes-Sainte-Radegonde', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Bors-de-Baignes', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Brettes', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Brigueuil', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Cellettes', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Champagne-Mouton', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Chantillac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Chasseneuil-sur-Bonnieure', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Cherves-Chatelars', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Confolens', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Coulonges', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Courcome', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Feuillade', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Fouquebrune', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Gente', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Grassac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/La-Chapelle', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/La-Chevrerie', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/La-Couronne', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/La-Faye', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/La-Foret-de-Tesse', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Lesignac-Durand', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Lessac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Ligne', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Lussac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Maine-de-Boixe', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Marcillac-Lanville', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Mouthiers-sur-Boeme', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Oradour-Fanais', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Saint-Coutant', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Saint-Fraigne', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Taponnat-Fleurignac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Terres-de-Haute-Charente', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Touverac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Vervant', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Villognon', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Xambes']),
    ('cher.gouv.fr', ARRAY['https://www.cher.gouv.fr/Actions-de-l-Etat/Risques-PPR-DDRM-DICRIM-PCS-IAL-ICPE-PAPI-PGRI-RGA-termites-merules/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Decisions-implicites', 'https://www.cher.gouv.fr/Actions-de-l-Etat/Risques-PPR-DDRM-DICRIM-PCS-IAL-ICPE-PAPI-PGRI-RGA-termites-merules/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Declaration-ICPE', 'https://www.cher.gouv.fr/Publications/Enquetes-publiques/AOEP-Avis-d-ouverture-d-enquete-publique', 'https://www.cher.gouv.fr/Publications/Enquetes-publiques/ICPE-Enquetes-publiques-Consultations-du-public/ICPE-autorisation-dossiers-de-demande-d-autorisation-avis-d-enquete-publique-de-consultation-parallelisee-et-participation-du-public-par-voie-electronique', 'https://www.cher.gouv.fr/Publications/Enquetes-publiques/Rapport-Enquetes-publiques', 'https://www.cher.gouv.fr/Publications/Participation-du-public-projets-amenagement-ou-equipement-incidence-environnement-territoire', 'https://www.cher.gouv.fr/Services-de-l-Etat/Presentation-des-services/DDT-Direction-departementale-des-territoires-du-Cher']),
    ('correze.gouv.fr', ARRAY['https://www.correze.gouv.fr/Publications/Annonces-avis/Avis-et-Decisions-du-prefet-accord-accord-avec-reserves-refus-et-arretes-complementaires', 'https://www.correze.gouv.fr/Publications/Annonces-avis/Consultations-du-public/PARC-PHOTOVOLTAIQUE-Enquete-publique-du-16-12-2025-au-14-01-2026-Projet-sur-commune-d-Albussac']),
    ('corse-du-sud.gouv.fr', ARRAY['https://www.corse-du-sud.gouv.fr/Outils2/Glossaire', 'https://www.corse-du-sud.gouv.fr/Publications/Annonces-judiciaires-et-legales/Installations-classees-pour-la-protection-de-l-environnement-ICPE', 'https://www.corse-du-sud.gouv.fr/Publications/Consultation-du-public/Enquetes-publiques']),
    ('cote-dor.gouv.fr', ARRAY['https://cloud.transnum-v2.ac-dijon.fr/index.php/s', 'https://www.bourgogne-franche-comte.developpement-durable.gouv.fr/les-projets-eoliens-en-bourgogne-franche-comte-a6762.html', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Agriculture.-foret-et-developpement-rural/Agriculture/Exploitations-agricoles-foncier-controle-des-structures/Etude-prealable-agricole-et-compensations-collectives-agricoles', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction.-logement/Connaissance-du-territoire/Portails-d-information-geographique-grand-public', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Commissaires-enqueteurs', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Publications-reglementaires-et-decisions-administratives/Autorisations', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Publications-reglementaires-et-decisions-administratives/Declarations', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Arnay-le-Duc', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Aubaine', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Darcey', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Esbarres', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Gommeville', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Larrey', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Lery', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Liernais', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Magny-sur-Tille', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Millery', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Saint-Mesmin', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Salives', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Thenissey', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Touillon', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Enquetes-publiques-concernant-les-projets-de-centrales-solaires-photovoltaiques/Veronnes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Eoliennes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Les-zones-d-acceleration-du-developpement-des-energies-renouvelables', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Photovoltaique', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/ARCONCEY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/BEAUMONT-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/BEUREY-BEAUGUAY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/BEZE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/BILLY-LES-CHANCEAUX', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/MISSERY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/MONTIGNY-MORNAY-VILLENEUVE-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/NOIDAN', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/POUILLY-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/SELONGEY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/Sur-plusieurs-communes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Enquetes-publiques-diverses/EGUILLY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/ANTHEUIL', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/ARCONCEY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/AUBAINE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/AVELANGES', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BEAUMONT-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BEUREY-BEAUGUAY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BEZE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BILLY-LES-CHANCEAUX', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BOUSSELANGE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BUSSEROTTE-ET-MONTENAILLE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/BUSSY-LE-GRAND', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CERILLY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CHAILLY-SUR-ARMANCON', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CHATELLENOT', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CHAZEUIL', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CRECEY-SUR-TILLE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CUSSY-LA-COLONNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/CUSSY-LE-CHATEL', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/ERINGES', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/ETALANTE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/ETORMAY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/FONTANGY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/GRANCEY-LE-CHATEAU-NEUVELLE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/GROSBOIS-LES-TICHEY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/LAIGNES', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/LONGECOURT-LES-CULETRE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MARCELLOIS', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MAREY-SUR-TILLE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MASSINGY-LES-VITTEAUX', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MINOT', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MISSERY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MOLINOT', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MONTAGNY-LES-SEURRE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MONTCEAU-ET-ECHARNANT', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/MONTIGNY-MORNAY-VILLENEUVE-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/NOIDAN', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/OIGNY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/ORAIN', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/POISEUL-LA-VILLE-ET-LAPERRIERE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/POISEUL-LES-SAULX', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/POUILLY-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/QUINCY-LE-VICOMTE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SACQUENAY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SAINT-JEAN-DE-BOEUF', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SAINT-MAURICE-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SAINT-REMY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SAINT-SEINE-SUR-VINGEANNE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SANTOSSE', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SAULX-LE-DUC', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SEIGNY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SELONGEY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/SUSSEY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/Sur-plusieurs-communes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/Sur-plusieurs-departements', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/THURY', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/VAL-MONT', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/VERDONNET', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/VILLEY-SUR-TILLE', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Enquetes-publiques/ICPE-dont-carrieres/PE-SAISY-SAS-COMMUNES-DE-SAISY-71-ET-AUBIGNY-LA-RONCE-21']),
    ('cotes-darmor.gouv.fr', ARRAY['https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Energie/Photovoltaique', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Consultation-du-public-Art-L.181-10-1-du-CE-Loi-Industrie-Verte', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Enquetes-publiques-Archivees', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Enquetes-publiques-ICPE-industrielles/SAINTE-TREPHINE-Societe-Les-Landes-de-Landizes-Parc-eolien-de-Landizes', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Participation-du-public-par-voie-electronique-article-L-123-19-2-du-code-de-l-environnement', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Securite-et-protection-de-la-population', 'https://www.cotes-darmor.gouv.fr/Publications/Autres-publications', 'https://www.cotes-darmor.gouv.fr/Publications/Enquetes-publiques2/Projet-de-centrale-photovoltaique-au-sol-a-Plouguernevel', 'https://www.cotes-darmor.gouv.fr/Publications/La-Lettre-des-services-de-l-Etat/2026']),
    ('creuse.gouv.fr', ARRAY['https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Eau-Milieux-aquatiques/Consultations-publiques-Informations-du-public/Mise-a-disposition-du-public-informations', 'https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Eolien/Parcs-eoliens', 'https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Photovoltaique/Parcs-photovoltaiques', 'https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Strategie-EnR-en-Creuse', 'https://www.creuse.gouv.fr/Publications/Espace-Presse/Communiques-et-dossiers-de-presse/Communiques-2019', 'https://www.creuse.gouv.fr/Publications/Les-Recueils-des-actes-administratifs/Annee-2022', 'https://www.creuse.gouv.fr/Publications/Les-Recueils-des-actes-administratifs/Annee-2025']),
    ('deux-sevres.gouv.fr', ARRAY['https://www.deux-sevres.gouv.fr/Actions-de-l-Etat/Amenagement-territoire-construction-logement/Transition-ecologique-et-energetique/Energies-renouvelables', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/BOUSSAIS', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/COURS', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/FOMPERRON', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/Fontivillie', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/IRAIS', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/LIMALONGES', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/LORETZ-D-ARGENTON', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/LUSSERAY', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/MELLE', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/NEUVY-BOUIN', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/PAMPROUX', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/ST-AUBIN-LE-CLOUD', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/ST-LAURS', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/ST-MAURICE-ETUSSON', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/ST-VARENT', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/THOUARS', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/VIENNAY', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/VOULMENTIN', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/ICPE-Installations-Classees-pour-la-protection-de-l-Environnement/Preuve-de-depot-d-une-declaration']),
    ('dordogne.gouv.fr', ARRAY['https://www.dordogne.gouv.fr/Actions-de-l-Etat/Environnement-Eau-Biodiversite-Risques/Participation-du-public/Archives', 'https://www.dordogne.gouv.fr/Actions-de-l-Etat/Environnement-Eau-Biodiversite-Risques/Participation-du-public/Consultation-du-public', 'https://www.dordogne.gouv.fr/Actions-de-l-Etat/Transition-ecologique-energie-climat/Energies-renouvelables', 'https://www.dordogne.gouv.fr/Publications/Cartotheque']),
    ('doubs.gouv.fr', ARRAY['https://www.doubs.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-Construction-Logement-et-Transports/Amenagement-et-developpement-durables/Enquetes-publiques/Autres-enquetes', 'https://www.doubs.gouv.fr/Actions-de-l-Etat/Environnement/Climat-Air-Energie/Le-Pole-Energies-renouvelables-du-Doubs-Pole-EnR/Reunions-plenieres-du-pole-EnR']),
    ('drome.gouv.fr', ARRAY['https://www.drome.gouv.fr/Actions-de-l-Etat/Agriculture.-forets-et-developpement-rural/Agriculture/Foncier-agricole/Compensation-collective-agricole', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-foncier-construction-et-habitat/Amenagement-du-territoire-et-foncier/Commission-Departementale-de-Protection-des-Espaces-Naturels-Agricoles-et-Forestiers-CDPENAF/Avis-de-la-commission/2020', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Environnement-eau-risques-naturels-et-technologiques/Environnement-eau/Installations-classees/ICPE-Declaration2/Preuves-de-depot-de-declaration', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique-Developpement-des-energies-renouvelables/Avis-sur-les-projets-en-cours-d-instruction', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique-Developpement-des-energies-renouvelables/Energies-renouvelables/Photovoltaique', 'https://www.drome.gouv.fr/Pied-de-page/AEE-Avis-de-l-Autorite-Environnementale', 'https://www.drome.gouv.fr/Pied-de-page/ICPE-Installation-Classee-pour-la-Protection-de-l-Environnement/ICPE-Arretes-de-prescriptions-complementaires-et-autorisations-temporaires', 'https://www.drome.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Commissaires-enqueteurs', 'https://www.drome.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-et-consultations-classees-par-ville', 'https://www.drome.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-et-consultations-en-cours']),
    ('eure-et-loir.gouv.fr', ARRAY['https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Climat-Air-Energie/Energies-renouvelables/IFER', 'https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Installations-classees/Cas-par-Cas/DECISIONS-PRISES', 'https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Installations-classees/Regimes-autorisation-et-enregistrement-annees-2016-a-2026/2019', 'https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Installations-classees/Regimes-autorisation-et-enregistrement-annees-2016-a-2026/2021', 'https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Installations-classees/Regimes-autorisation-et-enregistrement-annees-2016-a-2026/2022', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Consultation-du-Public-par-voie-electronique-L181-10-1-du-Code-de-l-Environnement/En-cours', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Consultation-du-Public-par-voie-electronique-L181-10-1-du-Code-de-l-Environnement/Terminees', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Consultation-du-public/Terminees/2021/ICPE', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Consultation-du-public/Terminees/2024', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/En-cours', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2018', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2019', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2020', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2021/DDT', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2021/ICPE-PC-SUP', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2022', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2023', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2024', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2025', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2026', 'https://www.eure-et-loir.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-2016', 'https://www.eure-et-loir.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-2017', 'https://www.eure-et-loir.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-2026']),
    ('eure.gouv.fr', ARRAY['https://www.eure.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Planification-et-gestion-econome-de-l-espace', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Consultations-enquetes-publiques-et-participation-du-public-par-voie-electronique-PPVE/Enquetes-publiques', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Consultations-enquetes-publiques-et-participation-du-public-par-voie-electronique-PPVE/PPVE', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Eolien', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Photovoltaique', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Patrimoine', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Planification-ecologique/Zones-d-acceleration-des-Energies-Renouvelables-ZAEnR', 'https://www.eure.gouv.fr/Publications/Recueil-des-actes-administratifs-RAA/RAA-2016', 'https://www.eure.gouv.fr/Publications/Recueil-des-actes-administratifs-RAA/RAA-2017', 'https://www.eure.gouv.fr/Publications/Recueil-des-actes-administratifs-RAA/RAA-2020', 'https://www.eure.gouv.fr/Publications/Recueil-des-actes-administratifs-RAA/RAA-2026']),
    ('finistere.gouv.fr', ARRAY['https://www.finistere.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Connaissance-du-territoire/Paysages', 'https://www.finistere.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Les-centrales-photovoltaiques-au-sol', 'https://www.finistere.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Les-eoliennes', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Decisions-recentes-relatives-aux-autorisations-environnementales-et-aux-installations-classees', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Enquetes-publiques/Enquete-Publique-Unique-hydroliennes-et-parc-photovoltaique-a-OUESSANT', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Mesures-de-police-administrative', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Participation-du-public-par-voie-electronique-PPVE']),
    ('gard.gouv.fr', ARRAY['https://www.gard.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-et-construction/Urbanisme', 'https://www.gard.gouv.fr/Actions-de-l-Etat/Environnement/Eaux-et-milieux-aquatiques/Reglementation/Dossier-Loi-sur-l-eau-constitution', 'https://www.gard.gouv.fr/Actions-de-l-Etat/Environnement/Foret', 'https://www.gard.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Classement-des-ICPE-par-communes-regimes-autorisation-et-enregistrement/Saint-Victor-la-Coste', 'https://www.gard.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Classement-des-ICPE-par-entreprises-regimes-autorisation-et-enregistrement', 'https://www.gard.gouv.fr/Publications/Consultation-du-public', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2018', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2019', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2021', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2022', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2023', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2024', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-publiees-en-2025', 'https://www.gard.gouv.fr/Publications/Environnement/Loi-sur-l-eau/Autorisation-loi-sur-l-eau', 'https://www.gard.gouv.fr/Publications/Environnement/Loi-sur-l-eau/Declaration-Loi-sur-l-eau', 'https://www.gard.gouv.fr/Publications/Environnement/Participation-du-public-aux-decisions-ayant-une-incidence-sur-l-environnement/Procedures-en-cours']),
    ('gers.gouv.fr', ARRAY['https://www.gers.gouv.fr/Actions-de-l-Etat/Agriculture/La-compensation-collective-agricole/Avis-du-Prefet-sur-les-etudes-prealables', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Environnement/AOEP-Avis-d-ouverture-d-enquetes-publiques/Enquetes-cloturees', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Environnement/AOEP-Avis-d-ouverture-d-enquetes-publiques/Enquetes-en-cours', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Environnement/Operations-d-amenagement-Declaration-d-Utilite-Publique-cessibilite-autres/Rapport-et-conclusions-des-commissaires-enqueteurs', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique/Energies-renouvelables', 'https://www.gers.gouv.fr/Publications/Avis-de-l-autorite-environnementale-et-cas-par-cas-hors-CPE']),
    ('gironde.gouv.fr', ARRAY['https://www.gironde.gouv.fr/Publications/Publications-legales/Enquetes-publiques-consultations-du-public-declarations-d-intention-decisions-examen-cas-par-cas/Enquete-publique-Consultation-du-public-2022']),
    ('haut-rhin.gouv.fr', ARRAY['https://www.haut-rhin.gouv.fr/Actions-de-l-Etat/Environnement/Sobriete-energetique-et-Transition-ecologique', 'https://www.haut-rhin.gouv.fr/Publications/Rapports-d-activite-des-services-de-l-Etat/Rapport-d-activite-2023-des-services-de-l-Etat/Articles-complets/Planifier-et-accelerer-la-transition-ecologique', 'https://www.haut-rhin.gouv.fr/Publications/Rapports-d-activite-des-services-de-l-Etat/Rapport-d-activite-2024-des-services-de-l-Etat/Accelerer-la-transition-ecologique-dans-le-Haut-Rhin']),
    ('haute-corse.gouv.fr', ARRAY['https://www.haute-corse.gouv.fr/Actions-de-l-Etat/Transition-ecologique-environnement-et-prevention-des-risques/Procedures-installations-classees-ICPE/Installations-soumises-a-declaration', 'https://www.haute-corse.gouv.fr/Publications/Appels-a-projets-Consultations-Enquetes-publiques/Consultations-publiques', 'https://www.haute-corse.gouv.fr/Publications/Appels-a-projets-Consultations-Enquetes-publiques/Enquetes-publiques/Enquetes-Environnement', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Arretes-sans-enquete-publique/Archives', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2016-a-2022/Recueils-des-actes-administratifs-2018', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2016-a-2022/Recueils-des-actes-administratifs-2019', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2023', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2024', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2026']),
    ('haute-garonne.gouv.fr', ARRAY['https://www.haute-garonne.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Climat-air-energie/Le-pole-energies-renouvelables', 'https://www.haute-garonne.gouv.fr/Actions-de-l-Etat/Environnement-eau-biodiversite-et-foret/Procedures-environnementales-et-Commissions-competentes/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Quelles-demarches-effectuer', 'https://www.haute-garonne.gouv.fr/Publications/Declarations-d-intention-enquetes-publiques-et-avis-de-l-autorite-environnementale/Urbanisme/Enquetes-publiques-achevees']),
    ('haute-loire.gouv.fr', ARRAY['https://www.haute-loire.gouv.fr/Actions-de-l-Etat/Agriculture/Gestion-du-foncier-agricole/Compensations-collectives-agricoles/Avis-du-Prefet-sur-les-etudes-prealables', 'https://www.haute-loire.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Environnement/Eau/Actes-administratifs-dans-le-domaine-de-l-eau/Recepisses-de-declaration-relatifs-a-l-eau', 'https://www.haute-loire.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Regime-d-autorisation', 'https://www.haute-loire.gouv.fr/Actions-de-l-Etat/Strategie-Eau-Air-Sol/Strategie-Eau-Air-Sol', 'https://www.haute-loire.gouv.fr/Publications/Enquetes-publiques-Etat/Autres-enquetes-publiques']),
    ('haute-marne.gouv.fr', ARRAY['https://www.haute-marne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme/Energies-renouvelables/Les-comites-consultatifs-sur-les-projets-eoliens-et-photovoltaiques-au-sol', 'https://www.haute-marne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme/Energies-renouvelables/Ressources-utiles', 'https://www.haute-marne.gouv.fr/Actions-de-l-Etat/Risques-naturels-et-technologiques/Installations-classees-pour-la-protection-de-l-environnement/Autorisation/Informations', 'https://www.haute-marne.gouv.fr/Actions-de-l-Etat/Risques-naturels-et-technologiques/Installations-classees-pour-la-protection-de-l-environnement/Autorisations-et-enregistrements-jusqu-au-31-mars-2021', 'https://www.haute-marne.gouv.fr/Publications/Enquetes-publiques/Construction-d-une-centrale-photovoltaique-au-sol-a-Vesaignes-sur-Marne-SAS-MANA-VSM']),
    ('haute-saone.gouv.fr', ARRAY['https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Commission-Departementale-de-Preservation-des-Espaces-Naturels-Agricoles-et-Forestiers-CDPENAF/Compensation-collective-agricole/Avis-sur-les-etudes-prealables-presentees', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Portail-energies-renouvelables', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Economie-et-emploi', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Arretes-d-autorisation-et-recepisses-de-declaration-au-titre-de-la-loi-sur-l-eau', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Enquetes-publiques/Autres', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Enquetes-publiques/Centrales-photovoltaiques', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Enquetes-publiques/Eoliennes', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Participation-du-public-par-voie-electronique', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Eoliennes', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Preuves-de-depot-de-declaration-agricole']),
    ('haute-savoie.gouv.fr', ARRAY['https://www.haute-savoie.gouv.fr/Actions-de-l-Etat/Votre-departement/Energies-renouvelables', 'https://www.haute-savoie.gouv.fr/Publications/Actions-participatives/Droit-a-l-information-sur-l-environnement/2025']),
    ('haute-vienne.gouv.fr', ARRAY['https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Avis-de-l-autorite-environnementale-et-examen-au-cas-par-cas', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Etat-d-avancement-des-projets-EnR', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Hydroelectricite', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Photovoltaique/Avis-et-dossiers-d-enquete-publique-observations-electroniques-du-public', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Pole-EnR-et-Transition-Energetique-de-la-Haute-Vienne/Calendrier-et-communiques-de-presse', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Pole-EnR-et-Transition-Energetique-de-la-Haute-Vienne/Les-presentations-thematiques', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/ZAEnR', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees-ICPE/Avis-et-dossier-d-enquetes-publiques-observations-du-public', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees-ICPE/Decisions', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees-ICPE/Rapports-et-conclusions-des-commissaires-enqueteurs', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Procedures-environnementales', 'https://www.haute-vienne.gouv.fr/Publications/Consultation-du-public/Consultations-passees', 'https://www.haute-vienne.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-en-cours', 'https://www.haute-vienne.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-passees/Autorisation-environnementale-et-permis-d-amenager-RN-147-2x2-voies']),
    ('hautes-alpes.gouv.fr', ARRAY['https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Agriculture-et-Foret/Agriculture/Foncier-agricole/Compensation-collective-agricole', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-logement/Droit-d-initiative', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Avis-Autorite-Environnementale', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Energies-renouvelables/Etat-des-lieux-et-recommandations', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Energies-renouvelables/Loi-d-acceleration-pour-les-energies-renouvelables-et-zones-d-acceleration', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Regime-de-la-declaration/Preuves-de-depot-de-declaration-et-arretes-prefectoraux', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Participation-du-public-Enquetes-publiques/Enquetes-environnementales', 'https://www.hautes-alpes.gouv.fr/Publications/Catalogue-des-ressources-d-ingenierie-locale/Par-structure/IT05-Ingenierie-territoriale-Hautes-Alpes', 'https://www.hautes-alpes.gouv.fr/Publications/Catalogue-des-ressources-d-ingenierie-locale/Par-structure/SyME05-Syndicat-mixte-d-energie', 'https://www.hautes-alpes.gouv.fr/Publications/Donnees-territoriales-cartographiques/Cartographies-interactives']),
    ('hautes-pyrenees.gouv.fr', ARRAY['https://www.hautes-pyrenees.gouv.fr/Actions-de-l-Etat/Environnement-et-risques-majeurs/Eau-et-milieux-aquatiques/Loi-sur-l-Eau/Arretes-d-autorisations-de-declarations-et-autres/5-Autres-declarations-et-autorisations/Declarations/Declarations-2026', 'https://www.hautes-pyrenees.gouv.fr/Actions-de-l-Etat/Environnement-et-risques-majeurs/Energies-renouvelables', 'https://www.hautes-pyrenees.gouv.fr/Actions-de-l-Etat/Environnement-et-risques-majeurs/Les-Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Arretes-Prefectoraux-d-Autorisations-et-Arretes-Complementaires/2019', 'https://www.hautes-pyrenees.gouv.fr/Actions-de-l-Etat/Environnement-et-risques-majeurs/Les-Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Arretes-Prefectoraux-relatifs-au-regime-declaratif', 'https://www.hautes-pyrenees.gouv.fr/Publications/Enquetes-publiques-et-consultation-du-Public/Avis-et-decisions-de-l-Autorite-Environnementale/Avis-Decisions-de-l-Autorite-Environnementale-hors-ICPE/Avis-de-l-A.E', 'https://www.hautes-pyrenees.gouv.fr/Publications/Enquetes-publiques-et-consultation-du-Public/Enquetes-publiques/Historique-des-enquetes-cloturees/PC-Centrales-photovoltaiques-au-sol', 'https://www.hautes-pyrenees.gouv.fr/Publications/Enquetes-publiques-et-consultation-du-Public/Participation-du-public-par-voie-electronique-PPVE']),
    ('hauts-de-seine.gouv.fr', ARRAY['https://www.hauts-de-seine.gouv.fr/Publications/Consultations-publiques-et-concertations-prealables']),
    ('herault.gouv.fr', ARRAY['https://www.herault.gouv.fr/Actions-de-l-Etat/Transition-energetique/Vous-etes-un-particulier', 'https://www.herault.gouv.fr/Publications/Consultation-du-public/ENQUETES-PUBLIQUES2/PHOTOVOLTAIQUE', 'https://www.herault.gouv.fr/Publications/Consultation-du-public/INSTALLATIONS-CLASSEES/PARCS-EOLIENS']),
    ('ille-et-vilaine.gouv.fr', ARRAY['https://www.ille-et-vilaine.gouv.fr/Actions-de-l-Etat/Environnement-et-energie/L-energie', 'https://www.ille-et-vilaine.gouv.fr/Publications/Consultations-publiques-et-concertations-prealables/Consultations-Publiques-Environnement/Consultations-publiques-environnementales-archivees/2024', 'https://www.ille-et-vilaine.gouv.fr/Publications/Consultations-publiques-et-concertations-prealables/Consultations-Publiques-Environnement/Consultations-publiques-environnementales-archivees/2025', 'https://www.ille-et-vilaine.gouv.fr/Publications/Publications-legales/Arretes-prefectoraux/Environnement', 'https://www.ille-et-vilaine.gouv.fr/Publications/Publications-legales/Enquetes-publiques']),
    ('indre-et-loire.gouv.fr', ARRAY['https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foret/Prevention-des-incendies', 'https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Commission-Departementale-de-Preservation-des-Espaces-Naturels-Agricoles-et-Forestiers-CDPENAF', 'https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transition-energetique', 'https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables', 'https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Environnement/Gestion-de-l-eau/Decisions-au-titre-de-la-loi-sur-l-eau/Declarations-relatives-a-la-loi-sur-l-eau', 'https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Risques-naturels-et-technologiques/Installations-classees-pour-la-protection-de-l-environnement/Arretes-d-autorisation-d-enregistrement-de-refus-et-preuves-de-depot-de-teledeclaration', 'https://www.indre-et-loire.gouv.fr/Publications/Avis-et-etudes-prealables-de-compensation-collective-agricole', 'https://www.indre-et-loire.gouv.fr/Publications/Demandes-d-examen-au-cas-par-cas', 'https://www.indre-et-loire.gouv.fr/Publications/Enquetes-publiques-en-cours', 'https://www.indre-et-loire.gouv.fr/Publications/Rapports-et-conclusions-des-enquetes-publiques', 'https://www.indre-et-loire.gouv.fr/Publications/Recueil-actes-administratifs/Annee-2022', 'https://www.indre-et-loire.gouv.fr/Publications/Recueil-actes-administratifs/Annee-2023']),
    ('indre.gouv.fr', ARRAY['https://www.indre.gouv.fr/Actions-de-l-Etat/Environnement/I.C.P.E/Dossier-Autorisation-ICPE/SAS-PARC-EOLIEN-EOLIENNES-DES-CERISES-FONTENAY', 'https://www.indre.gouv.fr/Actions-de-l-Etat/Environnement/L-Observatoire-Photographique-du-Paysage-et-du-Changement-Climatique-de-l-Indre-OPPCC-36/La-phototheque', 'https://www.indre.gouv.fr/Actions-de-l-Etat/Environnement/Operations-d-amenagement-Declaration-d-Utilite-Publique-cessibilite-captages-autres/Captages', 'https://www.indre.gouv.fr/Actions-de-l-Etat/Environnement/Transition-energetique', 'https://www.indre.gouv.fr/Publications/Enquetes-Publiques-autre-que-ICPE/IMPLANTATION-D-UNE-CENTRALE-PHOTOVOLTAIQUE-AU-SOL-D-UNE-SURFACE-DE-15-51-au-lieu-dit-Prise-des-Tardets-sur-la-commune-de-BELABRE']),
    ('isere.gouv.fr', ARRAY['https://www.isere.gouv.fr/Actions-de-l-Etat/Acceleration-de-la-transition-ecologique/Transition-energetique/Energies-renouvelables/Vous-etes-une-collectivite', 'https://www.isere.gouv.fr/Actions-de-l-Etat/Environnement/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Archives-ICPE-decisions-et-sanctions-et-mises-en-demeure2/ICPE-decisions-sanctions-et-mises-en-demeure-2022', 'https://www.isere.gouv.fr/Actions-de-l-Etat/Environnement/ICPE-Installations-classees-pour-la-protection-de-l-environnement/ICPE-decisions-sanctions-et-mises-en-demeure-2024', 'https://www.isere.gouv.fr/Publications/Atlas-des-territoires/Transition-energetique-Deplacements-Air-et-Bruit/Transition-energetique', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Consultation-du-public/Consultation-du-public-ICPE-2023', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2023', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2024', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2025', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2026', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Participation-du-public-par-voie-electronique-PPVE/PPVE-2024', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Rapports-d-enquetes/Archives/ARCHIVES-2018', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Rapports-d-enquetes/Archives/ARCHIVES-2019', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Rapports-d-enquetes/Archives/Archives-2022', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Rapports-d-enquetes/Rapports-d-enquetes-2025']),
    ('jura.gouv.fr', ARRAY['https://www.jura.gouv.fr/Actions-de-l-Etat/Environnement/Participation-et-consultation-du-public/Au-titre-du-code-de-l-environnement/Participation-et-consultation-du-public-terminee', 'https://www.jura.gouv.fr/Publications/Annonces-avis/Enquetes-publiques/Divers/Parc-Eolien-Mont-Sous-Vaudrey', 'https://www.jura.gouv.fr/Publications/Annonces-avis/Enquetes-publiques/Divers/Parc-Photovoltaique-CRAMANS', 'https://www.jura.gouv.fr/Publications/Annonces-avis/Mise-a-disposition-du-public']),
    ('landes.gouv.fr', ARRAY['https://www.landes.gouv.fr/Actions-de-l-Etat/Agriculture-et-Foret/Foret/Defrichement-et-gestion-forestiere', 'https://www.landes.gouv.fr/Actions-de-l-Etat/Eau.-Environnement.-Risques-Naturels-et-Technologiques/Eau-et-Peche/Arretes-et-recepisses-d-autorisation-au-titre-de-la-loi-sur-l-eau/Arretes-prefectoraux', 'https://www.landes.gouv.fr/Actions-de-l-Etat/Eau.-Environnement.-Risques-Naturels-et-Technologiques/Eau-et-Peche/Arretes-et-recepisses-d-autorisation-au-titre-de-la-loi-sur-l-eau/Recepisses-de-depot-de-dossier-de-declaration', 'https://www.landes.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique', 'https://www.landes.gouv.fr/Publications/Consultations-du-public', 'https://www.landes.gouv.fr/Publications/Publications-legales/Enquetes-publiques']),
    ('loir-et-cher.gouv.fr', ARRAY['https://www.loir-et-cher.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Amenagement-urbanisme/Commission-departementale-de-preservation-des-espaces-naturels-agricoles-et-forestiers-de-Loir-et-Cher-CDPENAF', 'https://www.loir-et-cher.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Amenagement-urbanisme/Fiscalite-de-l-urbanisme', 'https://www.loir-et-cher.gouv.fr/Actions-de-l-Etat/Developpement-durable-et-cadre-de-vie/Energie-Air-et-Climat/Energies-renouvelables', 'https://www.loir-et-cher.gouv.fr/Publications/Communiques-de-presse/Annee-2025', 'https://www.loir-et-cher.gouv.fr/Publications/Connaissance-des-Territoires/Le-chiffre-du-mois/Chiffres-de-2019', 'https://www.loir-et-cher.gouv.fr/Publications/Enquetes-publiques', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2018', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2019', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2020', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2022', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2023', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2024', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2025', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2026', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Etude-de-compensation-collective-agricole/La-Ferte-Saint-Cyr-Projet-de-complexe-touristique-des-Pommereaux', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Installations-classees/Arretes-prefectoraux', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Installations-classees/Installations-relevant-du-regime-de-la-declaration2', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Procedures-d-autorisation-ou-de-declaration-au-titre-de-la-loi-sur-l-eau/SAINT-VIATRE-Creation-forage-d-alimentation-eau-potable-SCI-Domaine-de-Chales']),
    ('loire-atlantique.gouv.fr', ARRAY['https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Developpement-durable-et-mobilite/Energies-renouvelables/Solaire-et-photovoltaique', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public-aux-decisions-ayant-une-incidence-sur-l-environnement/Consultations-terminees', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Avis-de-l-autorite-environnementale/Eolien', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Commission-departementale-de-la-nature-des-paysages-et-des-sites-CDNPS', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Installations-classees-ICPE2/Eolien', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Installations-classees-ICPE2/Installation-Industrielles', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Installations-classees-ICPE2/Regime-de-la-Declaration-preuves-de-depot/Donges', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Participation-du-public-par-voie-electronique-PPVE', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Photovoltaique', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Grands-projets/Parc-eolien-en-mer-a-Saint-Nazaire/Autorisations/Autorisations-du-parc-eolien2', 'https://www.loire-atlantique.gouv.fr/Publications/Communiques-de-Presse/Communique-2025']),
    ('loire.gouv.fr', ARRAY['https://www.loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-Urbanisme-et-construction/Planification-Documents-d-urbanisme/Document-cadre-photovoltaique', 'https://www.loire.gouv.fr/Actions-de-l-Etat/Environnement/Climat-et-energies/Les-energies-renouvelables/Accompagnement-des-porteurs-de-projets', 'https://www.loire.gouv.fr/Actions-de-l-Etat/Environnement/Climat-et-energies/Les-energies-renouvelables/Les-differentes-sources', 'https://www.loire.gouv.fr/Actions-de-l-Etat/Environnement/Climat-et-energies/Les-energies-renouvelables/Les-zones-d-acceleration/Foire-aux-questions', 'https://www.loire.gouv.fr/Publications/Consultation-du-public', 'https://www.loire.gouv.fr/Publications/Enquetes-publiques/Photovoltaique-Eolien']),
    ('loiret.gouv.fr', ARRAY['https://www.loiret.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Commissions-departementales/CDPENAF-Commission-departementale-de-la-preservation-des-espaces-naturels-agricoles-et-forestiers', 'https://www.loiret.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transition-energetique2/Energies-renouvelables-EnR', 'https://www.loiret.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transition-energetique2/Zone-d-acceleration-de-la-production-d-EnR-ZAER', 'https://www.loiret.gouv.fr/Actions-de-l-Etat/Environnement-eau-chasse-peche/Eau/Projets-soumis-a-la-loi-sur-l-eau/Publication-des-decisions-relatives-a-la-Loi-sur-l-eau/Operations-soumises-a-declaration', 'https://www.loiret.gouv.fr/Actions-de-l-Etat/Environnement-eau-chasse-peche/Installations-classees-pour-la-protection-de-l-environnement-I.C.P.E/Arretes-prefectoraux/Arretes-complementaires', 'https://www.loiret.gouv.fr/Actions-de-l-Etat/Environnement-eau-chasse-peche/Installations-classees-pour-la-protection-de-l-environnement-I.C.P.E/Arretes-prefectoraux/Autorisations', 'https://www.loiret.gouv.fr/Actions-de-l-Etat/Environnement-eau-chasse-peche/Installations-classees-pour-la-protection-de-l-environnement-I.C.P.E/Arretes-prefectoraux/Mises-en-demeure', 'https://www.loiret.gouv.fr/Actualite/Archives-actualites/2022', 'https://www.loiret.gouv.fr/Actualite/Archives-communiques-dossiers-de-presse/2025', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2021', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2022', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2023', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2024', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2025', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2026', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-en-cours-et-a-venir', 'https://www.loiret.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-departementaux/2015/Novembre-2015', 'https://www.loiret.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-departementaux/2016/Decembre-2016', 'https://www.loiret.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-departementaux/2017/Novembre-2017', 'https://www.loiret.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-departementaux/2019/Novembre-2019', 'https://www.loiret.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-departementaux/2024', 'https://www.loiret.gouv.fr/Publications/Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-departementaux/2025']),
    ('lot-et-garonne.gouv.fr', ARRAY['https://www.lot-et-garonne.gouv.fr/Actions-de-l-Etat/Agriculture/Etudes-prealables-agricoles', 'https://www.lot-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/EAU/Arretes-d-autorisation-et-recepisses-de-declaration-au-titre-de-la-loi-sur-l-eau', 'https://www.lot-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-Public', 'https://www.lot-et-garonne.gouv.fr/Publications/Publications-legales/Avis-d-ouverture-d-enquete-publique', 'https://www.lot-et-garonne.gouv.fr/Publications/Publications-legales/ICPE/Declarations-Preuves-de-depot']),
    ('lot.gouv.fr', ARRAY['https://www.lot.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-ecologie-et-logement/Projets-energies-renouvelables/2-les-projets-en-cours', 'https://www.lot.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Archives-jusqu-en-2020/Archives-ICPE-jusqu-en-2014', 'https://www.lot.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Photovoltaique', 'https://www.lot.gouv.fr/Publications/Participations-du-public/Anciennes-participations-du-public/Enquetes-publiques-2013', 'https://www.lot.gouv.fr/Publications/Participations-du-public/Anciennes-participations-du-public/Enquetes-publiques-2015', 'https://www.lot.gouv.fr/Publications/Participations-du-public/Anciennes-participations-du-public/Enquetes-publiques-2024', 'https://www.lot.gouv.fr/Publications/Participations-du-public/Droit-d-initiative-citoyenne', 'https://www.lot.gouv.fr/Publications/Recueil-des-Actes-Administratifs/Archives-du-RAA/RAA-2020', 'https://www.lot.gouv.fr/Publications/Recueil-des-Actes-Administratifs/RAA-2022', 'https://www.lot.gouv.fr/Publications/Recueil-des-Actes-Administratifs/RAA-2023']),
    ('lozere.gouv.fr', ARRAY['https://www.lozere.gouv.fr/Actions-de-l-Etat/Environnement-Risques-naturels-et-technologiques/Consultation-du-public', 'https://www.lozere.gouv.fr/Actions-de-l-Etat/Environnement-Risques-naturels-et-technologiques/Energies-renouvelables/Energie-eolienne', 'https://www.lozere.gouv.fr/Publications/Autres-publications/Les-articles-archives-du-site', 'https://www.lozere.gouv.fr/Publications/Enquetes-publiques-Participation-du-public/Enquetes-publiques-environnementales/Enquetes-publiques-environementales', 'https://www.lozere.gouv.fr/Publications/Enquetes-publiques-Participation-du-public/Enquetes-publiques-environnementales/Installations-classees-pour-la-protection-de-l-environnement-autorisation']),
    ('maine-et-loire.gouv.fr', ARRAY['https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Eau-et-Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-Enregistrement-Sanction/Autorisation/Annee-2018/arrondissement-de-Segre', 'https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Eau-et-Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-Enregistrement-Sanction/Autorisation/Annee-2023/Installations-classees', 'https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Eau-et-Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-Enregistrement-Sanction/Autorisation/Annee-2024', 'https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Transition-Ecologique/Energies-Renouvelables-EnR/Le-pole-energies-renouvelables/Presentation-du-pole-EnR', 'https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Transition-Ecologique/Energies-Renouvelables-EnR/Les-differentes-filieres/Eolien', 'https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Urbanisme-Paysage-Accessibilite-Construction-Logement/Commissions-CDAC-CDPENAF/CDPENAF-Preservation-des-espaces-naturels-agricoles-et-forestiers', 'https://www.maine-et-loire.gouv.fr/Publications/Autorite-environnementale/Archives-Autorite-Environnementale', 'https://www.maine-et-loire.gouv.fr/Publications/Autorite-environnementale/Avis-de-l-autorite-environnementale', 'https://www.maine-et-loire.gouv.fr/Publications/Autorite-environnementale/Decision-implicite', 'https://www.maine-et-loire.gouv.fr/Publications/Consultation-du-public/Consultations-en-cours/Consultation-par-voie-electronique-Loi-industrie-verte', 'https://www.maine-et-loire.gouv.fr/Publications/Consultation-du-public/Consultations-en-cours/ICPE', 'https://www.maine-et-loire.gouv.fr/Publications/Consultation-du-public/Consultations-terminees/Autres-thematiques/ANNEE-2025', 'https://www.maine-et-loire.gouv.fr/Publications/Enquetes-publiques/Autres', 'https://www.maine-et-loire.gouv.fr/Publications/Enquetes-publiques/Installation-Classee-pour-la-Protection-de-l-Environnement-ICPE/Annee-2023', 'https://www.maine-et-loire.gouv.fr/Publications/Enquetes-publiques/Installation-Classee-pour-la-Protection-de-l-Environnement-ICPE/Annee-2024', 'https://www.maine-et-loire.gouv.fr/Publications/Enquetes-publiques/Installation-Classee-pour-la-Protection-de-l-Environnement-ICPE/Annee-2025']),
    ('manche.gouv.fr', ARRAY['https://www.manche.gouv.fr/Publications/Annonces-et-avis/Arretes/Environnement', 'https://www.manche.gouv.fr/Publications/Annonces-et-avis/Consultations-publiques/Especes-protegees', 'https://www.manche.gouv.fr/Publications/Annonces-et-avis/Enquetes-publiques']),
    ('marne.gouv.fr', ARRAY['https://www.marne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire/Urbanisme/Procedures-d-amenagement/Etude-Prealable-de-Compensation-Agricole-EPCA', 'https://www.marne.gouv.fr/Actions-de-l-Etat/Environnement/Examen-au-cas-par-cas/CRISTAL-UNION-Etablissement-CRISTANOL-Bazancourt-projet-GLUTEN', 'https://www.marne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Documentation-et-imprimes', 'https://www.marne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Dossiers-ICPE-Autorisation/Dossiers-ICPE-Autorisation-Domaine-eolien', 'https://www.marne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Dossiers-ICPE-Declaration/2019', 'https://www.marne.gouv.fr/Actions-de-l-Etat/Environnement/Nature-Foret-et-Chasse/Chasse', 'https://www.marne.gouv.fr/Publications/Appels-a-projets-consultations/Enquetes-publiques/Autres-enquetes', 'https://www.marne.gouv.fr/Publications/Appels-a-projets-consultations/Enquetes-publiques/Corbeille/POS-de-Dormans', 'https://www.marne.gouv.fr/Publications/Appels-a-projets-consultations/Enquetes-publiques/Enquete-publique-Urbanisme', 'https://www.marne.gouv.fr/contenu/telechargement/51100/364770/file', 'https://www.marne.gouv.fr/contenu/telechargement/51101/364775/file', 'https://www.marne.gouv.fr/contenu/telechargement/51102/364780/file']),
    ('mayenne.gouv.fr', ARRAY['https://www.mayenne.gouv.fr/Actions-de-l-Etat/Energie-et-Climat/Energies-renouvelables', 'https://www.mayenne.gouv.fr/Actions-de-l-Etat/Environnement-eau-et-biodiversite/Enquetes-publiques-hors-ICPE-Commissaires-enqueteurs/Divers', 'https://www.mayenne.gouv.fr/Actions-de-l-Etat/Environnement-eau-et-biodiversite/Installations-classees/Installations-classees-industrielles-carrieres/Autorisation', 'https://www.mayenne.gouv.fr/Actions-de-l-Etat/Environnement-eau-et-biodiversite/Installations-classees/Installations-classees-industrielles-carrieres/Mesures-de-police-administrative']),
    ('meurthe-et-moselle.gouv.fr', ARRAY['https://www.meurthe-et-moselle.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire/Commission-Departementale-de-la-Preservation-des-Espaces-Naturels-Agricoles-et-Forestiers/Etude-prealable-agricole-et-mesures-de-compensation-agricole-collective2', 'https://www.meurthe-et-moselle.gouv.fr/Actions-de-l-Etat/Enquetes-et-consultations-publiques/Consultations-publiques2', 'https://www.meurthe-et-moselle.gouv.fr/Actions-de-l-Etat/Enquetes-et-consultations-publiques/Enquetes-publiques/Consulter-les-enquetes-publiques-en-cours']),
    ('meuse.gouv.fr', ARRAY['https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/L-energie-eolienne', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Gestion-de-l-eau/Decisions-Loi-sur-l-Eau/Declaration-loi-sur-l-eau', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/ICPE/Eoliennes', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public/Consultations-en-cours-ou-a-venir', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public/Suites-des-consultations-rapports-d-enquetes-et-decisions']),
    ('morbihan.gouv.fr', ARRAY['https://www.morbihan.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Energies/Eolien-en-mer', 'https://www.morbihan.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Energies/La-loi-d-acceleration-de-la-production-d-energies-renouvelables', 'https://www.morbihan.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Energies/PPE-3-programmation-pluriannuelle-de-l-energie', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/BULEON', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/CARO', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/CREDIN', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/FORGES-DE-LANOUEE-Lanouee-et-Les-Forges', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/GUEHENNO', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/GUELTAS', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/MAURON', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/MENEAC', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/PLOERDUT', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/VAL-D-OUST-La-Chapelle-Caro-Quily-et-Le-Roc-Saint-Andre', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-de-mesures-de-police-administrative/Mesures-de-police-administrative', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Declaration-procedure-dematerialisee-et-arretes-de-prescriptions-speciales/LANGONNET', 'https://www.morbihan.gouv.fr/Publications/Participation-du-public/Concertations-prealables-et-declarations-d-intention-terminees', 'https://www.morbihan.gouv.fr/Publications/Participation-du-public/Consultations-publiques-terminees/Derogation-a-la-protection-stricte-des-especes/Derogation-especes-protegees-Suivi-environnemental-parc-eolien-Gueltas-Noyal-Pontivy', 'https://www.morbihan.gouv.fr/Publications/Participation-du-public/Consultations-publiques-terminees/Installations-photovoltaiques-au-sol', 'https://www.morbihan.gouv.fr/Publications/Participation-du-public/Enquetes-publiques-terminees', 'https://www.morbihan.gouv.fr/Publications/Police-de-l-Eau-IOTA-actes-delivres/1-Recepisses-de-declaration-arretes-de-prescriptions/SEGLIEN']),
    ('moselle.gouv.fr', ARRAY['https://www.moselle.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/Accompagnement-des-porteurs-de-projets', 'https://www.moselle.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/Planification-des-energies-renouvelables/Document-cadre', 'https://www.moselle.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/Planification-des-energies-renouvelables/Zones-d-acceleration-des-energies-renouvelables', 'https://www.moselle.gouv.fr/Publications/Actu-Moselle-Le-magazine-de-l-Etat-en-Moselle/Annee-2022/Fevier-2022-La-lettre-des-services-de-l-Etat-en-Moselle-n-47', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Forbach-Boulay-Moselle', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Metz', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Sarrebourg-Chateau-Salins', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Sarreguemines', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Thionville', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Autorite-environnementale', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Publication-des-avis-CDPENAF']),
    ('nievre.gouv.fr', ARRAY['https://www.nievre.gouv.fr/Actions-de-l-Etat/Agriculture/2-Structures-des-exploitations-et-gestion-du-foncier2/CDPENAF/Compensation-collective/Etudes-prealables-et-avis-rendus', 'https://www.nievre.gouv.fr/Actions-de-l-Etat/Environnement', 'https://www.nievre.gouv.fr/Actions-de-l-Etat/Transition-energetique', 'https://www.nievre.gouv.fr/Publications/Autres-publications-obligatoires', 'https://www.nievre.gouv.fr/Publications/Consultation-et-participation-publique', 'https://www.nievre.gouv.fr/Publications/Enquetes-publiques-Etat', 'https://www.nievre.gouv.fr/Publications/Participation-du-public']),
    ('nord.gouv.fr', ARRAY['https://www.nord.gouv.fr/Actions-de-l-Etat/Amenagement-urbanisme-habitat-et-construction/Amenagement-urbanisme-et-planification/Les-documents-locaux-de-planification-PLU-i-PLU-Carte-Communale/Les-porter-a-connaissance-realises/Delegation-territoriale-de-AVESNES/Elaboration-du-PLUi-de-la-C.C.P.M-communaute-de-communes-du-Pays-de-Mormal/Etudes-et-donnees-complementaires/Milieux-naturels-paysage-RLPI-et-patrimoine', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Amenagement-urbanisme-habitat-et-construction/Amenagement-urbanisme-et-planification/Les-documents-locaux-de-planification-PLU-i-PLU-Carte-Communale/Les-porter-a-connaissance-realises/Delegation-territoriale-de-AVESNES/Elaboration-du-PLUi-de-la-C.C.S.A-Communaute-de-Communes-Sud-Avesnois/Etudes-et-donnees-complementaires/Milieux-naturels-paysages-et-patrimoine', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Amenagement-urbanisme-habitat-et-construction/Amenagement-urbanisme-et-planification/Les-documents-locaux-de-planification-PLU-i-PLU-Carte-Communale/Les-porter-a-connaissance-realises/Delegation-territoriale-de-AVESNES/Elaboration-du-PLUi-de-la-CCCA-Communaute-de-Communes-du-Coeur-de-l-Avesnois/Etudes-et-donnees-complementaires/Milieux-naturels-paysage-RLPI-et-patrimoine', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Police-de-l-eau/Consultations-participations-et-enquetes-publiques/Enquetes-publiques-IOTA', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Police-de-l-eau/Decisions/2022', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/CODERST/Seances-2024', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Les-projets-photovoltaiques', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Permis/Permis-de-construire-2019', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Permis/Permis-de-construire-2023', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Permis/Permis-de-construire-2024/Construction-d-une-centrale-photovoltaique-au-sol-sur-la-commune-de-Wahagnies', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Permis/Permis-de-construire-2025', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Urbanisme/Plan-local-d-urbanisme', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2019', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2020', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2022', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2024', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2025', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Donner-acte', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Prescriptions-complementaires', 'https://www.nord.gouv.fr/Demarches']),
    ('oise.gouv.fr', ARRAY['https://www.oise.gouv.fr/Actions-de-l-Etat/Actualite/Archives/2016', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Actualite/Archives/2017', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Actualite/Archives/2018/La-ministre-du-travail-en-deplacement-a-BASF-et-ENERCON', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Agriculture/Commission-departementale-de-preservation-des-espaces-naturels-agricoles-et-forestiers-CDPENAF/La-compensation-collective-agricole/Avis-de-la-CDPENAF-et-du-Prefet-sur-les-etudes-prealables-agricoles', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Agriculture/Projet-agricole-departemental-PAD-du-departement-de-l-Oise', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Application-du-droit-des-sols-ADS-dans-l-Oise/Note-ADS', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Enquetes-publiques-de-l-urbanisme/Base-aerienne-de-Creil-Enquete-publique-Projet-de-centrale-photovoltaique', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Enquetes-publiques-de-l-urbanisme/Breteuil-projet-de-centrale-photovoltaique-presente-par-CS-du-Cakempin', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Enquetes-publiques-de-l-urbanisme/Fitz-James-projet-d-implantation-de-panneaux-solaires-photovoltaiques', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Enquetes-publiques-de-l-urbanisme/Rosieres-Versigny-projet-d-une-centrale-agrivoltaique', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Enquetes-publiques-de-l-urbanisme/Trosly-Breuil-projet-de-centrale-photovoltaique-presente-par-CPV-SUN-40-LUXEL', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Enquetes-publiques-de-l-urbanisme/Villers-Saint-Paul-projet-de-centrale-photovoltaique-presente-par-la-societe-TOTAL-SOLAR', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/L-Agence-nationale-de-cohesion-des-territoires-dans-l-Oise/Le-comite-local-de-cohesion-territoriale', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/La-connaissance-de-l-Oise/Atlas-cartographique', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/La-connaissance-de-l-Oise/Formation-IDE/Loi-APER-ombrieres-photovoltaiques', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Transition-Ecologique-et-Energetique/Document-cadre-photovoltaique', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Transition-Ecologique-et-Energetique/Energies-renouvelables/Guichet-unique-de-l-energie/Concertation-dans-le-cadre-des-projets-Photovoltaiques', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Transition-Ecologique-et-Energetique/Energies-renouvelables/La-loi-d-acceleration-pour-les-energies-renouvelables', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees/Par-arretes', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees/Par-enquete-publique/Archives-EP-anterieures-a-2016', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees/Par-societe', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Environnement/Nature-et-Biodiversite/Especes-et-habitats-proteges/Consultation-du-public-close']),
    ('orne.gouv.fr', ARRAY['https://www.orne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire/Urbanisme-operationnel/Permis-de-construire-et-autres-autorisations-d-urbanisme/Les-enquetes-publiques/Demande-de-permis-de-construire-pour-une-centrale-photovoltaique-au-sol-a-Boischampre', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Protection-de-l-environnement/Enquetes-publiques.-participation-et-consultation-du-public/Les-enquetes-publiques-consultations-et-participations-du-public/MOULINS-SUR-ORNE-Parc-eolien-des-Houdonnieres', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Protection-de-l-environnement/Enquetes-publiques.-participation-et-consultation-du-public/Rapports-et-Conclusions-des-commissaires-enqueteurs', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Protection-de-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Eoliens/MONTS-SUR-ORNE-CENTRALE-EOLIENNE-LES-HAUTS-VAUDOIS', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Eolien/Le-schema-eolien-de-Basse-Normandie', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Eolien/Les-arretes-prefectoraux-relatifs-a-la-creation-de-zones-de-developpement-eolien', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Photovoltaique/Les-projets-de-centrales-photovoltaiques-dans-l-Orne/CHATEAU-D-ALMENECHES-projet-de-centrale-photovoltaique', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Photovoltaique/Les-projets-de-centrales-photovoltaiques-dans-l-Orne/COLONARD-CORUBERT-le-projet-de-centrale-photovoltaique', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Photovoltaique/Les-projets-de-centrales-photovoltaiques-dans-l-Orne/RAI-Societe-Le-Val-Solaire', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Photovoltaique/Les-projets-de-centrales-photovoltaiques-dans-l-Orne/SAINTE-SCOLASSE-SUR-SARTHE-le-projet-de-centrale-photovoltaique', 'https://www.orne.gouv.fr/Publications/Espace-presse/Discours', 'https://www.orne.gouv.fr/Publications/Espace-presse/Les-communiques-de-presse/Les-communiques-2021', 'https://www.orne.gouv.fr/Publications/Espace-presse/Les-communiques-de-presse/Les-communiques-2024']),
    ('pas-de-calais.gouv.fr', ARRAY['https://www.pas-de-calais.gouv.fr/Actions-de-l-Etat/Environnement-developpement-durable/Eau/Procedures-loi-sur-l-eau-Actes-administratifs/Autorisations-Loi-sur-l-eau/2024', 'https://www.pas-de-calais.gouv.fr/Actions-de-l-Etat/Environnement-developpement-durable/Installations-classees', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Demande-d-autorisation-de-porter-atteinte-a-des-arbres-d-allees-ou-d-alignements', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Enquetes-publiques/EOLIENNES', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Enquetes-publiques/Permis-de-construire', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Participation-du-public-par-voie-electronique']),
    ('puy-de-dome.gouv.fr', ARRAY['https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Construction.-habitat-et-logement-social/Construction/Architecture-et-environnement/Les-aides-en-faveur-de-l-habitat', 'https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Eau/Depliants.-formulaires.-decisions', 'https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Arretes-complementaires', 'https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisations-environnementales/Dossiers-autorisations-environnementales-Puy-de-Dome', 'https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisations-environnementales/projets-hors-departement', 'https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Photovoltaique', 'https://www.puy-de-dome.gouv.fr/Publications/Enquetes-publiques/2022']),
    ('pyrenees-atlantiques.gouv.fr', ARRAY['https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-planification-et-urbanisme-construction/Enquetes-publiques/Closes/SASU-TRINA-SOLAR-FRANCE-SYSTEMS-a-Gabaston-Centrale-photovoltaique-au-sol', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-planification-et-urbanisme-construction/Enquetes-publiques/En-cours', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Cadre-de-vie-eau-environnement-et-risques-majeurs/Avis-de-l-autorite-environnementale', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Cadre-de-vie-eau-environnement-et-risques-majeurs/Gestion-de-l-eau/Declaration-autorisations/2020/Juillet-2020', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Cadre-de-vie-eau-environnement-et-risques-majeurs/Gestion-de-l-eau/Declaration-autorisations/2020/Juin-2020', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Cadre-de-vie-eau-environnement-et-risques-majeurs/Gestion-de-l-eau/Declaration-autorisations/2021/Octobre-2021', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Cadre-de-vie-eau-environnement-et-risques-majeurs/Gestion-de-l-eau/Declaration-autorisations/2025']),
    ('pyrenees-orientales.gouv.fr', ARRAY['https://www.pyrenees-orientales.gouv.fr/Actions-de-l-Etat/Environnement-eau-risques-naturels-et-technologiques/Energies-renouvelables/Mieux-comprendre-les-energies-renouvelables', 'https://www.pyrenees-orientales.gouv.fr/Actions-de-l-Etat/Environnement-eau-risques-naturels-et-technologiques/Energies-renouvelables/Planifier-les-energies-renouvelables/Document-cadre-pour-les-installations-photovoltaiques-sur-terrains-agricoles-naturels-et-forestiers', 'https://www.pyrenees-orientales.gouv.fr/Actions-de-l-Etat/Mer-littoral-et-securite-maritime', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Autorisations-loi-sur-l-eau', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Enquetes-publiques-Photovoltaique/Energies-des-Bouzigues-Saint-Feliu-d-Avall', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Enquetes-publiques-Photovoltaique/Perpignan-Mas-Romeu-ARKOLIA2', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Enquetes-publiques-Photovoltaique/Ponteilla-Nyls-Mas-Becha', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Etudes-prealables-agricoles', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/ICPE-Installations-Classees-Protection-Environnement-soumises-a-autorisation']),
    ('saone-et-loire.gouv.fr', ARRAY['https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Agriculture/Foncier/Compensation-collective-agricole/Etudes-prealables', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme-construction-habitat/CDPENAF-commission-de-preservation-des-espaces-naturels.-agricoles-et-forestiers', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme-construction-habitat/Climat-et-energie/Schema-regional-climat-air-energie-SRCAE', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme-construction-habitat/Energies-renouvelables', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Decisions-administratives-individuelles/Decisions-IOTA/Declarations', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Decisions-administratives-individuelles/Decisions-IPCE', 'https://www.saone-et-loire.gouv.fr/Demarches', 'https://www.saone-et-loire.gouv.fr/Pied-de-page']),
    ('sarthe.gouv.fr', ARRAY['https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Eau/Loi-sur-l-eau/Decisions-dans-le-domaine-de-l-eau2', 'https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Installations-Classees/Autorisations-Enregistrements', 'https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Installations-Classees/Declarations/Consultation-par-commune', 'https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Les-energies-renouvelables', 'https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Transition-energetique-et-ecologique', 'https://www.sarthe.gouv.fr/Publications/Consultations-et-enquetes-publiques']),
    ('savoie.gouv.fr', ARRAY['https://www.savoie.gouv.fr/Actions-de-l-Etat/Paysages-environnement-risques-naturels-et-technologiques/Environnement/Eau-foret-biodiversite/Avis-d-enquetes-publiques-Consultations-du-public-parallelisees-loi-industrie-verte', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Paysages-environnement-risques-naturels-et-technologiques/Environnement/Eau-foret-biodiversite/Rapports-de-commissaires-enqueteurs', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique-amenagement-du-territoire-construction-logement/Transition-energetique-et-ecologique/Transition-energetique', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique-amenagement-du-territoire-construction-logement/Urbanisme-et-amenagement/Avis-d-enquetes-publiques-urbanisme/Epierre', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique-amenagement-du-territoire-construction-logement/Urbanisme-et-amenagement/Avis-d-enquetes-publiques-urbanisme/La-Balme', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique-amenagement-du-territoire-construction-logement/Urbanisme-et-amenagement/Rapports-commissaires-enqueteurs-urbanisme', 'https://www.savoie.gouv.fr/Publications/Enquetes-publiques']),
    ('seine-et-marne.gouv.fr', ARRAY['https://www.seine-et-marne.gouv.fr/Actions-de-l-Etat/Agriculture/Preservation-du-Foncier-Agricole/COMPENSATION-AGRICOLE-COLLECTIVE/Compensation-agricole-collective', 'https://www.seine-et-marne.gouv.fr/Actions-de-l-Etat/Climat-Energies/Transition-energetique-et-developpement-des-ENR', 'https://www.seine-et-marne.gouv.fr/Actions-de-l-Etat/Environnement-et-cadre-de-vie/Commissions-consultatives-CODERST-CDNPS-CSS-CCE-et-CLCS/CDNPS', 'https://www.seine-et-marne.gouv.fr/Publications/Enquetes-publiques/LA-GRANDE-PAROISSE-PROJET-DE-CENTRALE-PHOTOVOLTAIQUE-FLOTTANTE']),
    ('seine-maritime.gouv.fr', ARRAY['https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/La-demarche-d-identification-des-zones-d-acceleration-des-energies-renouvelables-ZAEnR', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Arretes-CoDERST-et-arretes-hors-sanctions/3-ARRETES-PAR-COMMUNES/CRIQUIERS', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Arretes-CoDERST-et-arretes-hors-sanctions/3-ARRETES-PAR-COMMUNES/MONTREUIL-EN-CAUX', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Commission-departementale-de-la-nature-des-paysages-et-des-sites-CDNPS/ARRETES-PARCS-EOLIENS', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Developpement-durable/Energies-Renouvelables2', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Eau-et-milieux-aquatiques/4-Consultation-des-dossiers-loi-sur-l-eau/2024', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Consultations-du-public/00-ENREGISTREMENT-ICPE/2024/LUNERAY', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Consultations-du-public/01-ESPECES-PROTEGEES', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/AUZOUVILLE-SUR-SAANE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/BAILLOLET', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/BEAUSSAULT', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/BELLEVILLE-EN-CAUX', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/BOSC-MESNIL', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/BRACQUETUIT', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/CALLENGEVILLE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/CLAIS', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/DROSAY', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/ENVRONVILLE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/FALLENCOURT', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/FESQUES', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/GUERVILLE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/ILLOIS', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/LE-MESNIL-REAUME', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/MONCHY-SUR-EU', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/RONCHOIS', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/SAINT-MACLOU-LA-BRIERE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/SAINT-PIERRE-LE-VIGER', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/SAINT-VAAST-D-EQUIQUEVILLE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/SMERMESNIL', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/WANCHY-CAPVAL', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/PARCS-EOLIENS-EN-MER/PARC-EOLIEN-EN-MER-AU-LARGE-DE-FECAMP/RAPPORTS-COMMISSAIRE-ENQUETEUR-COMMISSIONS-D-ENQUETE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/PARCS-EOLIENS-EN-MER/PROJET-D-INSTALLATION-D-UN-PARC-EOLIEN-EN-MER-ENTRE-DIEPPE-ET-LE-TREPORT', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/Permis-de-Construire/Projet-de-construction-d-une-centrale-photovoltaique-au-sol-a-Arelaune-en-Seine', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/Permis-de-Construire/Projet-de-construction-d-une-centrale-photovoltaique-au-sol-a-Oissel-sur-Seine', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Risques-technologiques-et-naturels/Territoires-a-Risque-Important-d-Inondation-TRI/TRI-du-Havre/Strategie-Locale', 'https://www.seine-maritime.gouv.fr/Publications/Barometre-de-l-action-publique']),
    ('somme.gouv.fr', ARRAY['https://www.somme.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire/Foncier/Compensations-collectives-agricoles', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Autorite-environnementale-Avis-sur-les-evaluations-environnementales', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Environnement-Consultations-publiques', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Eolien', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Photovoltaique/Participations-du-public-par-voie-electronique-et-decisions', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Observatoire-des-territoires/Amenagement-du-territoire-et-urbanisme/Les-webinaires-de-la-DDTM-de-la-Somme-un-nouveau-regard-sur-l-amenagement', 'https://www.somme.gouv.fr/Actualite']),
    ('tarn-et-garonne.gouv.fr', ARRAY['https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Cadre-general-de-mise-en-oeuvre-de-projets-d-energies-renouvelables', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Informations-aux-developpeurs', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-environnementales/Autorisation-environnementale-unique', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-environnementales/Enquetes-publiques-hors-ICPE', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-environnementales/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Regime-d-autorisation']),
    ('tarn.gouv.fr', ARRAY['https://www.tarn.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foncier-agricole-autorisations-et-compensation/Preservation-des-espaces-et-compensation-agricole-collective', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement-urbanisme-commercial/Urbanisme-habitat-ingenierie/Autorisations-d-urbanisme-permis-de-construire-ou-d-amenager', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Eau/Decisions-et-arretes-pris-dans-le-domaine-de-l-eau-dans-le-81/Eaux-pluviales-Eaux-Usees', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Eau/Decisions-et-arretes-pris-dans-le-domaine-de-l-eau-dans-le-81/Travaux-sur-cours-d-eau-et-en-zones-humides', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Eau/Dossier-loi-sur-l-eau-Marche-a-suivre', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Arretes-d-autorisation-enregistrement-police-environnementale-et-decision', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Avis-d-enquetes-publiques-de-consultation-du-public-et-declarations-d-intention-de-projet', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Avis-de-l-autorite-environnementale', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Declarations-ICPE/Preuve-de-depot', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Dossier-d-enquete-et-resume-non-technique-du-dossier', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Rapports-et-conclusions-commissaire-enqueteur', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/La-planification-ecologique/Energies-renouvelables', 'https://www.tarn.gouv.fr/Publications/Communiques-de-presse/Archives/Communiques-2013', 'https://www.tarn.gouv.fr/Publications/Participation-du-public/Participation-ou-consultation-du-Public/Procedures-terminees-et-resultats-de-la-participation', 'https://www.tarn.gouv.fr/Publications/RAA-Recueil-des-Actes-Administratifs/RAA/2026/Fevrier']),
    ('territoire-de-belfort.gouv.fr', ARRAY['https://www.territoire-de-belfort.gouv.fr/Actions-de-l-Etat/Ecologie/Energies-renouvelables', 'https://www.territoire-de-belfort.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public-consultations-et-enquetes-publiques/Participation-du-public-consultations-et-enquetes-publiques-closes']),
    ('val-de-marne.gouv.fr', ARRAY['https://www.val-de-marne.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Environnement-loi-sur-l-eau-geothermie-dechets-publicite-sols-pollues-bruit', 'https://www.val-de-marne.gouv.fr/Publications/Enquetes-publiques-et-concertations-prealables']),
    ('var.gouv.fr', ARRAY['https://www.var.gouv.fr/Actions-de-l-Etat/Agriculture/Compensation-collective-agricole', 'https://www.var.gouv.fr/Actions-de-l-Etat/Biodiversite-et-Nature/Sequence-eviter.-reduire-et-compenser-ERC-les-impacts-sur-les-milieux-naturels/Lignes-directrices-guides-et-referentiels', 'https://www.var.gouv.fr/Actions-de-l-Etat/Eau/Loi-sur-l-eau-et-actes-administratifs-declaration-autorisation-et-DIG/Actes-administratifs-issus-de-l-instruction-des-dossiers-loi-sur-l-eau/2019', 'https://www.var.gouv.fr/Actions-de-l-Etat/Eau/Loi-sur-l-eau-et-actes-administratifs-declaration-autorisation-et-DIG/Actes-administratifs-issus-de-l-instruction-des-dossiers-loi-sur-l-eau/2020', 'https://www.var.gouv.fr/Actions-de-l-Etat/Eau/Loi-sur-l-eau-et-actes-administratifs-declaration-autorisation-et-DIG/Actes-administratifs-issus-de-l-instruction-des-dossiers-loi-sur-l-eau/2021', 'https://www.var.gouv.fr/Actions-de-l-Etat/Eau/Loi-sur-l-eau-et-actes-administratifs-declaration-autorisation-et-DIG/Actes-administratifs-issus-de-l-instruction-des-dossiers-loi-sur-l-eau/2022', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Des-cles-pour-comprendre', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Plans-et-projets-par-communes/Artigues', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Plans-et-projets-par-communes/Meounes-Les-Montrieux', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Plans-et-projets-par-communes/Ollieres', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Projets-d-arretes-prefectoraux-soumis-a-participation-du-public/Defrichement', 'https://www.var.gouv.fr/Actions-de-l-Etat/France-Relance/Portraits-de-la-Relance-dans-le-Var-et-laureats', 'https://www.var.gouv.fr/Publications/Consultations-du-public', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-hors-ICPE', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Toutes-les-enquetes-publiques-cloturees/2021', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Toutes-les-enquetes-publiques-cloturees/2022', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Toutes-les-enquetes-publiques-cloturees/2023', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Toutes-les-enquetes-publiques-cloturees/2024', 'https://www.var.gouv.fr/Publications/Loi-sur-l-eau', 'https://www.var.gouv.fr/Publications/RAA-Recueil-des-actes-administratifs/Recueil-des-actes-administratifs-2021']),
    ('vaucluse.gouv.fr', ARRAY['https://www.vaucluse.gouv.fr/Actions-de-l-Etat/Securite/Reglementation-et-demarches-en-relation-avec-la-securite-et-la-defense-civiles/Pollution-de-l-air', 'https://www.vaucluse.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-prevention-des-risques/Transition-energetique.-energies-renouvelables/Le-photovoltaique-en-Vaucluse', 'https://www.vaucluse.gouv.fr/Archives-internet-Prefecture/La-lettre-de-l-Etat-en-Vaucluse/Numero-6-Juillet-2011/A-la-Une-le-Grenelle-de-l-environnement', 'https://www.vaucluse.gouv.fr/Pied-de-page/AEE-Avis-de-l-Autorite-Environnementale/Liste-des-avis-de-l-autorite-environnementale', 'https://www.vaucluse.gouv.fr/Publications/Enquete-publique-Consultation-parallelisee-PPVE-Enregistrement-Hors-procedure-particuliere/Liste-des-enquetes-publiques/2.-Saint-Trinit-Projet-de-construction-d-une-centrale-solaire-photovoltaique-au-sol', 'https://www.vaucluse.gouv.fr/Publications/Enquete-publique-Consultation-parallelisee-PPVE-Enregistrement-Hors-procedure-particuliere/Liste-des-enquetes-publiques/Centrale-photovotaique-a-Orange-ouverture-d-une-enquete-publique-du-02-12-2024-au-08-01-2025/Centrale-photovoltaique-a-Bollene-ouverture-d-une-enquete-publique-du-28-02-2024-au-29-03-2024', 'https://www.vaucluse.gouv.fr/Publications/Enquete-publique-Consultation-parallelisee-PPVE-Enregistrement-Hors-procedure-particuliere/Liste-des-enquetes-publiques/Centrale-photovotaique-a-Orange-ouverture-d-une-enquete-publique-du-02-12-2024-au-08-01-2025/Centrale-photovoltaique-a-Caderousse-ouverture-d-une-enquete-publique-du-04-09-2023-au-04-10-2023', 'https://www.vaucluse.gouv.fr/Publications/Enquete-publique-Consultation-parallelisee-PPVE-Enregistrement-Hors-procedure-particuliere/Liste-des-enquetes-publiques/Courthezon-Projet-de-construction-d-une-centrale-solaire-photovoltaique-au-sol']),
    ('vendee.gouv.fr', ARRAY['https://www.vendee.gouv.fr/Actions-de-l-Etat/Developpement-des-territoires/Compensation-agricole-collective/Etudes-prealables', 'https://www.vendee.gouv.fr/Actions-de-l-Etat/Energie', 'https://www.vendee.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Decisions-et-arretes', 'https://www.vendee.gouv.fr/Publications/Demande-de-cas-par-cas-ESSOC', 'https://www.vendee.gouv.fr/Publications/Enquetes-publiques', 'https://www.vendee.gouv.fr/Publications/Participation-du-public/Participation-du-public-par-voie-electronique-declaration-d-intention']),
    ('vienne.gouv.fr', ARRAY['https://www.vienne.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Preservation-des-espaces-agricoles', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement/Amenagement-du-territoire/Energies-renouvelables', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-Loi-industrie-verte-LIV/Centrale-photovoltaique', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Eau-et-milieux-aquatiques/Projets-soumis-a-la-loi-sur-l-eau/Decisions-et-arretes-20252', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Enquete-publique/Centrale-photovoltaique', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees/Eoliennes']),
    ('vosges.gouv.fr', ARRAY['https://www.vosges.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement-et-developpement-durable-et-fonds-europeens-Accessibilite/Eolien-photovoltaique', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Consultation-dematerialisee-du-public', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Installations-classees-soumises-a-autorisation', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Installations-classees-soumises-a-enregistrement', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Projet-photovoltaique', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Environnement/Commissions-consultatives/CDNPS/Formation-sites-et-paysages', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-Pour-l-Environnement-ICPE/Arrete-de-rejet', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Rur-agilite-laboratoire-de-la-ruralite-au-service-de-tous-les-territoires-ruraux/L-actu-du-labo']),
    ('yonne.gouv.fr', ARRAY['https://www.yonne.gouv.fr/Actions-de-l-Etat/Collectivites-locales-et-intercommunalites/Intercommunalite/Reunion-des-presidents-d-EPCI', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Culture-Tourisme-et-Patrimoine/Projet-du-Grand-Vezelay', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Consultation', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Energie/Energie-renouvelable/Eolien', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Energie/Energie-renouvelable/Les-zones-d-acceleration-des-energies-renouvelables-ZAER', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Consultation-publique', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Declarations', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Enquetes-Publiques', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Prescriptions-complementaires', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Prolongation-d-examen-autorisation-environnementale', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Rejet-dossier-autorisation-environnementale', 'https://www.yonne.gouv.fr/Publications/Publications-legales/Declarations-loi-sur-l-eau']),
    ('yvelines.gouv.fr', ARRAY['https://www.yvelines.gouv.fr/Actions-de-l-Etat/Batiments-et-Villes-Durables/Outils-de-planification-et-d-amenagement-durables', 'https://www.yvelines.gouv.fr/Actions-de-l-Etat/Environnement/Environnement/Eau', 'https://www.yvelines.gouv.fr/Publications/Consultation-du-public', 'https://www.yvelines.gouv.fr/Publications/Enquetes-publiques/Urbanisme-Amenagement'])
) AS h(domain, urls)
WHERE s.domain = h.domain
  AND s.source_type = 'prefecture';

DO $$ BEGIN RAISE NOTICE 'Schema news migre avec succes'; END $$;

'@
    Write-FileUTF8NoBOM -Path "$($script:CONFIG.InstallPath)\config\init.sql" -Content $sqlContent
}

# ==============================================================================
#  Execution du SQL dans le PostgreSQL MRAE partage
#
#  A la difference de MRAE Scraper (qui monte init.sql comme volume execute
#  automatiquement au demarrage de postgres), ici postgres est deja en place.
#  On copie donc init.sql dans le conteneur mrae_postgres et on le joue via
#  psql -f.
# ==============================================================================
function Invoke-InitSQL {
    $sqlFile = "$($script:CONFIG.InstallPath)\config\init.sql"

    if (-not (Test-Path $sqlFile)) {
        Write-Fail "init.sql introuvable : $sqlFile"
        return $false
    }

    $pgState = docker inspect --format "{{.State.Running}}" $script:CONFIG.MRAEPostgres 2>&1
    if ($pgState -ne "true") {
        Write-Fail "PostgreSQL MRAE non accessible - demarrez la stack MRAE d'abord"
        return $false
    }

    Write-Step "Copie de init.sql dans $($script:CONFIG.MRAEPostgres)..."
    docker cp $sqlFile "$($script:CONFIG.MRAEPostgres):/tmp/news_init.sql" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "Echec de la copie dans le conteneur" ; return $false }

    Write-Step "Execution du SQL..."
    # PowerShell 5.1 cree un RemoteException des qu'une commande native ecrit
    # sur stderr, meme quand elle reussit (code de sortie 0). psql ecrit tous
    # ses NOTICE sur stderr. On neutralise donc $ErrorActionPreference pendant
    # l'appel, et on s'appuie uniquement sur $LASTEXITCODE (+ ON_ERROR_STOP=1)
    # pour detecter les vraies erreurs. On convertit chaque element en string
    # pour s'assurer que les ErrorRecord sont affiches lisiblement.
    $previousEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $psqlOutput = docker exec $script:CONFIG.MRAEPostgres psql `
            -U $script:CONFIG.DBUser `
            -d $script:CONFIG.DBName `
            -v ON_ERROR_STOP=1 `
            -f /tmp/news_init.sql 2>&1
        $psqlExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEAP
    }
    # Affichage brut : forcer la conversion en string pour voir les ErrorRecord
    $psqlOutput | ForEach-Object { "$_" } | Out-Host

    if ($psqlExit -ne 0) {
        Write-Fail "Execution SQL terminee en erreur (code $psqlExit)"
        return $false
    }

    # Nettoyage du fichier temporaire dans le conteneur
    docker exec $script:CONFIG.MRAEPostgres rm -f /tmp/news_init.sql 2>&1 | Out-Null

    Write-OK "Schema news initialise"
    return $true
}