# ==============================================================================
#  modules/database.ps1
#  Generation des fichiers d'infrastructure : .env, docker-compose.yml,
#  init.sql  +  execution du SQL dans le PostgreSQL MRAE partage.
# ==============================================================================

function New-EnvFile {
    param([string]$DBPassword)

    Write-FileUTF8NoBOM -Path $script:CONFIG.EnvFile -Content @"
# NEWS Scraper - Variables d'environnement  (ne pas committer dans git)

DB_HOST=$($script:CONFIG.MRAEPostgres)
DB_PORT=5432
DB_NAME=$($script:CONFIG.DBName)
DB_USER=$($script:CONFIG.DBUser)
DB_PASSWORD=$DBPassword
DB_SCHEMA=news

SEARXNG_URL=http://news_searxng:8080
SEARXNG_CONCURRENCY=1
SEARXNG_QUERY_DELAY_SEC=3
SEARXNG_MAX_SOURCES=20
SEARXNG_MAX_COMMUNES=5
SEARXNG_CACHE_TTL_HOURS=24

TIKA_URL=http://mrae_tika:9998

FETCH_CONCURRENCY=10
FETCH_PER_DOMAIN_MAX=2
FETCH_TIMEOUT_SEC=15
FETCH_TEXT_MAX_CHARS=50000
URL_CACHE_TTL_DAYS=30

REDIS_URL=redis://news_redis:6379/0

OLLAMA_MODEL_NLP=qwen2.5:7b
OLLAMA_TIMEOUT=600
OLLAMA_ENABLED=true

LOG_LEVEL=INFO
"@
}

function New-DockerCompose {
    Write-FileUTF8NoBOM -Path $script:CONFIG.ComposeFile -Content @"
# NEWS Scraper - Docker Compose
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
      - ./output:/app/output
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

  $($script:CONFIG.SharedNetwork):
    external: true
"@
}

function New-InitSQL {
    $sqlContent = @'
-- ==============================================================================
-- NEWS Scraper - Schema news
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS news;

-- ==============================================================================
-- Table sources
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.sources (
    id              SERIAL PRIMARY KEY,
    domain          TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,
    source_type     TEXT NOT NULL,
    signal_type     TEXT CHECK (signal_type IN (
                       'reglementaire', 'enquete', 'presse', 'porteur'
                    )),
    is_structured   BOOLEAN DEFAULT FALSE,
    is_active       BOOLEAN DEFAULT TRUE,
    discovery_mode  TEXT DEFAULT 'searxng_site' CHECK (discovery_mode IN (
                       'searxng_site', 'crawl_index', 'internal'
                    )),
    index_urls      TEXT[],
    hubs_discovered_at  TIMESTAMPTZ,
    reliability_score   FLOAT DEFAULT 0.5,
    freshness_score     FLOAT DEFAULT 0.5,
    early_signal_score  FLOAT DEFAULT 0.5,
    cost_score          FLOAT DEFAULT 0.5,
    created_at      TIMESTAMP DEFAULT NOW()
);

-- ==============================================================================
-- Couverture geographique
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
-- Affinite source <-> type ENR
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.source_enr_affinity (
    source_id       INT  REFERENCES news.sources(id) ON DELETE CASCADE,
    enr_type_code   TEXT CHECK (enr_type_code IN ('photovoltaique','agrivoltaique','eolien')),
    affinity_score  FLOAT DEFAULT 0.5,
    PRIMARY KEY (source_id, enr_type_code)
);

-- ==============================================================================
-- Cache de fetch d'URLs
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.url_cache (
    url             TEXT PRIMARY KEY,
    http_status     INT,
    content_type    TEXT,
    fetch_method    TEXT,
    text            TEXT,
    text_length     INT,
    fetch_duration  FLOAT,
    error           TEXT,
    fetched_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_url_cache_fetched ON news.url_cache (fetched_at);

-- ==============================================================================
-- Cache SearXNG
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.searxng_cache (
    query           TEXT PRIMARY KEY,
    results         JSONB NOT NULL,
    n_results       INTEGER NOT NULL,
    fetched_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_searxng_cache_fetched ON news.searxng_cache (fetched_at);

-- ==============================================================================
-- Resultats de jobs (candidats projets par URL)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS news.job_results (
    url             TEXT NOT NULL,
    job_id          UUID NOT NULL,
    status          TEXT NOT NULL,
    method          TEXT,
    is_enr_project  BOOLEAN,
    relevance_score FLOAT,
    candidate       JSONB,
    duration        FLOAT,
    error           TEXT,
    extracted_at    TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (url, job_id)
);

CREATE INDEX IF NOT EXISTS idx_job_results_job    ON news.job_results (job_id);
CREATE INDEX IF NOT EXISTS idx_job_results_status ON news.job_results (status);
CREATE INDEX IF NOT EXISTS idx_job_results_url    ON news.job_results (url);

-- ==============================================================================
-- Index utiles
-- ==============================================================================
CREATE INDEX IF NOT EXISTS idx_sources_active ON news.sources(is_active);

-- ==============================================================================
-- Fonction get_best_sources
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
    discovery_mode       TEXT,
    index_urls           TEXT[],
    hubs_discovered_at   TIMESTAMPTZ,
    niveau               TEXT,
    final_score          FLOAT
)
LANGUAGE sql STABLE AS $func$
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
                WHEN LTRIM(dept_code, '0') = LTRIM(p_dept, '0') THEN 3
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
        s.discovery_mode,
        s.index_urls,
        s.hubs_discovered_at,
        cov.niveau,
        (
              0.3                                              * 0.5
            + s.reliability_score                              * 0.2
            + s.freshness_score                                * 0.1
            + s.early_signal_score                             * 0.1
            + COALESCE(a.affinity_score, 0.5)                  * 0.1
            - s.cost_score                                     * 0.1
            + CASE
                WHEN LTRIM(cov.dept_code, '0') = LTRIM(p_dept, '0') THEN 0.2
                WHEN cov.region_name = p_region THEN 0.1
                WHEN cov.niveau      = 'national' THEN 0.05
                ELSE 0
              END
            + CASE WHEN s.discovery_mode = 'internal' THEN 0.3 ELSE 0 END
        )::float AS final_score
    FROM news.sources s
    JOIN best_coverage cov ON cov.source_id = s.id
    LEFT JOIN news.source_enr_affinity a
        ON a.source_id     = s.id
       AND a.enr_type_code = p_enr_type
    WHERE s.is_active = TRUE
    ORDER BY final_score DESC
    LIMIT p_limit;
$func$;


-- ==============================================================================
-- Fonction get_internal_avis
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
-- Fonction get_communes_in_radius
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
-- SEED : sources non-prefecture
-- Scores theoriques bases sur experience metier.
-- Les prefectures sont dans le second INSERT ci-dessous avec leurs hub URLs.
-- source_type : officiel | enquete_publique | presse_specialisee | presse_locale | developer
-- signal_type : reglementaire | enquete | presse | porteur
-- ==============================================================================
INSERT INTO news.sources
    (domain, name, source_type, signal_type, is_structured, discovery_mode,
     reliability_score, freshness_score, early_signal_score, cost_score)
VALUES
    -- Source interne MRAE (SQL direct, pas de crawl web)
    ('mrae.avis', 'MRAE_DB', 'officiel', 'reglementaire',
     TRUE, 'internal', 1.00, 0.90, 1.00, 0.10),
    -- Registres EP dematerialises
    ('registre-dematerialise.fr', 'Registre Dematerialise', 'enquete_publique', 'enquete',
     TRUE, 'searxng_site', 0.80, 0.80, 0.90, 0.45),
    ('dematamp.fr', 'Dematamp', 'enquete_publique', 'enquete',
     TRUE, 'searxng_site', 0.75, 0.70, 0.85, 0.40),
    -- Presse specialisee ENR
    ('pv-magazine.fr', 'PV Magazine', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.85, 0.90, 0.70, 0.20),
    ('greenunivers.com', 'GreenUnivers', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.80, 0.85, 0.75, 0.20),
    ('actu-environnement.com', 'Actu Environnement', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.85, 0.85, 0.75, 0.20),
    ('lemoniteur.fr', 'Le Moniteur', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.75, 0.75, 0.65, 0.25),
    ('enerzine.com', 'Enerzine', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.70, 0.80, 0.70, 0.20),
    ('revolution-energetique.com', 'Revolution Energetique', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.70, 0.75, 0.65, 0.20),
    ('lendosphere.com', 'Lendosphere', 'presse_specialisee', 'presse',
     FALSE, 'searxng_site', 0.75, 0.60, 0.85, 0.20),
    -- Presse locale
    ('midilibre.fr',     'Midi Libre',              'presse_locale', 'presse', FALSE, 'searxng_site', 0.65, 0.80, 0.55, 0.25),
    ('ladepeche.fr',     'La Depeche',              'presse_locale', 'presse', FALSE, 'searxng_site', 0.65, 0.80, 0.55, 0.25),
    ('sudouest.fr',      'Sud Ouest',               'presse_locale', 'presse', FALSE, 'searxng_site', 0.65, 0.80, 0.55, 0.25),
    ('ouest-france.fr',  'Ouest France',            'presse_locale', 'presse', FALSE, 'searxng_site', 0.65, 0.90, 0.55, 0.25),
    ('letelegramme.fr',  'Le Telegramme',           'presse_locale', 'presse', FALSE, 'searxng_site', 0.65, 0.85, 0.55, 0.25),
    ('lamontagne.fr',    'La Montagne',             'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.70, 0.55, 0.25),
    ('leprogres.fr',     'Le Progres',              'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.70, 0.55, 0.25),
    ('ledauphine.com',   'Le Dauphine Libere',      'presse_locale', 'presse', FALSE, 'searxng_site', 0.65, 0.80, 0.55, 0.25),
    ('estrepublicain.fr','Est Republicain',         'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.70, 0.55, 0.25),
    ('dna.fr',           'DNA',                     'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.70, 0.55, 0.25),
    ('lavoixdunord.fr',  'La Voix du Nord',         'presse_locale', 'presse', FALSE, 'searxng_site', 0.70, 0.85, 0.60, 0.25),
    ('lanouvellerepublique.fr','Nouvelle Republique','presse_locale','presse', FALSE, 'searxng_site', 0.65, 0.80, 0.55, 0.25),
    ('leberry.fr',       'Le Berry Republicain',    'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.75, 0.55, 0.25),
    ('larepubliquedespyrenees.fr','Republique des Pyrenees','presse_locale','presse',FALSE,'searxng_site',0.60,0.75,0.55,0.25),
    ('laprovence.com',   'La Provence',             'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.75, 0.55, 0.25),
    ('nicematin.com',    'Nice Matin',              'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.75, 0.55, 0.25),
    ('varmatin.com',     'Var Matin',               'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.75, 0.55, 0.25),
    ('bienpublic.com',   'Le Bien Public',          'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.70, 0.55, 0.25),
    ('paris-normandie.fr','Paris Normandie',        'presse_locale', 'presse', FALSE, 'searxng_site', 0.60, 0.70, 0.55, 0.25)
ON CONFLICT (domain) DO NOTHING;

-- ==============================================================================
-- SEED : 43 developpeurs ENR (Phase 3 searxng_site)
-- source_type='developer' pour _load_developer_names() dans l agent
-- ==============================================================================
INSERT INTO news.sources
    (domain, name, source_type, signal_type, is_structured,
     reliability_score, freshness_score, early_signal_score, cost_score,
     discovery_mode, index_urls)
VALUES
    ('aboenergy.com',   'ABO Energy',    'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.aboenergy.com/fr/developpement-construction/references/index.html','https://www.aboenergy.com/fr/zone-information/nos-projets/index.html']),
    ('akuoenergy.com',  'Akuo Energy',   'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://akuoenergy.com/presse','https://akuoenergy.com/akuo-dans-le-monde/tous-nos-projets']),
    ('alterric-france.fr','Alterric',    'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.alterric-france.fr/nos-parcs','https://www.alterric-france.fr/actualites']),
    ('arkolia.com',     'Arkolia Energies','developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://arkolia.com/fr/projets']),
    ('baywa-re.fr',     'BayWa r.e.',    'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.baywa-re.fr/fr/newsroom']),
    ('boralex.com',     'Boralex',       'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://boralex.com/en/projects-and-sites','https://boralex.com/en/news']),
    ('ciel-et-terre.net','Ciel et Terre','developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://ciel-et-terre.net/fr/references','https://ciel-et-terre.net/fr/nos-actus']),
    ('cnr.tm.fr',       'CNR',           'developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://www.cnr.tm.fr/actualites/?_categories=energies-renouvelables']),
    ('direction-france.totalenergies.fr','TotalEnergies','developer','porteur',FALSE,0.75,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://direction-france.totalenergies.fr/nos-actualites','https://direction-france.totalenergies.fr/nos-communiques-de-presse']),
    ('elements.green',  'Elements Green','developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.elements.green/nos-projets','https://www.elements.green/blog']),
    ('energieteam.fr',  'EnergieTEAM',  'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.energieteam.fr/nos-projets','https://www.energieteam.fr/presse/communiques-de-presse']),
    ('energiter.fr',    'Energiter',     'developer','porteur',FALSE,0.75,0.60,0.90,0.30,'searxng_site',
     ARRAY['https://www.energiter.fr/references','https://www.energiter.fr/nos-actualites']),
    ('enertrag.com',    'Enertrag',      'developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://enertrag.com/fr/projets','https://enertrag.com/fr/actualites']),
    ('engie.com',       'Engie Green',   'developer','porteur',FALSE,0.75,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.engie.com/references-energies-renouvelables']),
    ('eolfi.com',       'EOLFI',         'developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://eolfi.com/blog']),
    ('ergfrance.fr',    'ERG France',    'developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://www.ergfrance.fr/actualites','https://www.ergfrance.fr/nos-implantations']),
    ('greenyellow.com', 'GreenYellow',   'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.greenyellow.com/realisation-greenyellow-projets-clients/?metiers=production-energie-solaire']),
    ('groupevaleco.com','Valeco',        'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://groupevaleco.com/category/actualites','https://groupevaleco.com/espace-presse']),
    ('groupe-volta.com','Groupe Volta',  'developer','porteur',FALSE,0.65,0.55,0.75,0.30,'searxng_site',
     ARRAY['https://www.groupe-volta.com/actualites']),
    ('iberdrola.fr',    'Iberdrola',     'developer','porteur',FALSE,0.75,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://www.iberdrola.fr/a-propos-iberdrola/media/presse']),
    ('ibvogt.fr',       'IB Vogt',       'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.ibvogt.fr/projets-en-developpement','https://www.ibvogt.fr/news']),
    ('iel-energie.com', 'IEL',           'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.iel-energie.com/nos-realisations','http://iel-energie.com/actus']),
    ('innovent.fr',     'Innovent',      'developer','porteur',FALSE,0.65,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://innovent.fr/actualites']),
    ('jpee.fr',         'JPEE',          'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.jpee.fr/actualites','https://www.jpee.fr/nos-realisations']),
    ('kallistaenergy.com','Kallista Energy','developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.kallistaenergy.com/nos-realisations','https://www.kallistaenergy.com/actualites-kallista-energy']),
    ('nassetwind.com',  'Nass et Wind',  'developer','porteur',FALSE,0.65,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://nassetwind.com/actualites']),
    ('neoen.com',       'Neoen',         'developer','porteur',FALSE,0.75,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://neoen.com/fr/actualites']),
    ('photosol.fr',     'Photosol',      'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.photosol.fr/realisations']),
    ('qair.energy',     'Qair',          'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://france.qair.energy/actualites']),
    ('qenergy.eu',      'Q Energy',      'developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://qenergy.eu/fr/media/communiques-de-presse']),
    ('reden.solar',     'Reden Solar',   'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://reden.solar/actualites']),
    ('renner-energies.com','Renner Energies','developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://www.renner-energies.com/fr/eolien?country=FR','https://www.renner-energies.com/fr/news']),
    ('sepale.com',      'Sepale',        'developer','porteur',FALSE,0.65,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://sepale.com/projets','https://sepale.com/actualites']),
    ('solveo-energies.com','Solveo Energie','developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://solveo-energies.com/references','https://solveo-energies.com/actualites']),
    ('tenergie.fr',     'Tenergie',      'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://tenergie.fr/actualites']),
    ('tse.energy',      'TSE',           'developer','porteur',FALSE,0.70,0.60,0.90,0.30,'searxng_site',
     ARRAY['https://www.tse.energy/realisations-agrivoltaique-photovoltaique','https://www.tse.energy/actualites-expert-energie-solaire']),
    ('unit-e.fr',       'UNITe',         'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://unit-e.fr/nos-energies/nos-implantations','https://unit-e.fr/ressources/actus']),
    ('urbasolar.com',   'Urbasolar',     'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.urbasolar.com/nos-actus']),
    ('valorem-energie.com','Valorem',    'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.valorem-energie.com/realisations','https://www.valorem-energie.com/actualites']),
    ('vensolair.fr',    'Vensolair',     'developer','porteur',FALSE,0.65,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://vensolair.fr/actualites']),
    ('voltalia.com',    'Voltalia',      'developer','porteur',FALSE,0.75,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.voltalia.com/fr/case-study','https://www.voltalia.com/fr/in-the-news']),
    ('vsb.energy',      'VSB Energies',  'developer','porteur',FALSE,0.70,0.55,0.80,0.30,'searxng_site',
     ARRAY['https://www.vsb.energy/fr/fr/references','https://www.vsb.energy/fr/fr/actualites/presse']),
    ('wpd.fr',          'wpd France',    'developer','porteur',FALSE,0.70,0.60,0.85,0.30,'searxng_site',
     ARRAY['https://www.wpd.fr/leolien/nos-realisations-et-projets-eoliens','https://www.wpd.fr/le-solaire/nos-parcs-solaires-en-developpement','https://www.wpd.fr/presse'])
ON CONFLICT (domain) DO UPDATE SET
    name             = EXCLUDED.name,
    source_type      = EXCLUDED.source_type,
    signal_type      = EXCLUDED.signal_type,
    discovery_mode   = EXCLUDED.discovery_mode,
    index_urls       = EXCLUDED.index_urls,
    is_active        = TRUE;

-- ==============================================================================
-- SEED : 96 PREFECTURES
--
-- Toutes les prefectures sont inserees en mode crawl_index avec leurs hub URLs.
-- Les 5 prefectures sans hubs connus (Essonne, Paris, Rhone,
-- Seine-Saint-Denis, Val-d Oise) ont index_urls=NULL : elles seront
-- ignorees par le crawl_index (aucun projet ENR significatif attendu).
-- ==============================================================================
INSERT INTO news.sources
    (domain, name, source_type, signal_type, is_structured,
     reliability_score, freshness_score, early_signal_score, cost_score,
     discovery_mode, index_urls, hubs_discovered_at)
VALUES
    ('ain.gouv.fr', 'Prefecture Ain', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Autorisations-d-urbanisme/Projets-photovoltaiques', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Construire-et-renover', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transitions-energetique-et-ecologique/Accompagnement-dans-la-transition', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transitions-energetique-et-ecologique/Developpement-des-energies-renouvelables', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Urbanisme-et-amenagement-durables/Preservation-du-foncier/Commission-departementale-de-preservation-des-espaces-naturels.-agricoles-et-forestiers-CDPENAF', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Conference-environnementale', 'https://www.ain.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees/Preuves-de-depots', 'https://www.ain.gouv.fr/Publications/Enquetes-publiques/Installations-classees-pour-l-environnement', 'https://www.ain.gouv.fr/Publications/Enquetes-publiques/Projets-photovoltaiques', 'https://www.ain.gouv.fr/Publications/Enquetes-publiques/Urbanisme'], NOW()),
    ('aisne.gouv.fr', 'Prefecture Aisne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Consultations-publiques/Energie/Document-cadre-photovoltaique', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Consultations-publiques/ICPE', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Enquetes-publiques/ICPE', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Consultations-et-Enquetes-publiques/Enquetes-publiques/Urbanisme', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Avis-de-l-autorite-environnementale/Avis-de-l-AE/ICPE', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Eau/Police-de-l-Eau/Declarations-au-titre-de-la-loi-sur-l-eau', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Energies-et-transition-ecologique', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Arretes-de-mesures-de-police-administrative', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-environnementale/Dossiers-d-enquete-publique', 'https://www.aisne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisation-environnementale/Dossiers-de-consultation-du-public-dite-parallelisee', 'https://www.aisne.gouv.fr/Publications/Espace-presse/Communiques-et-dossiers-de-presse-2020', 'https://www.aisne.gouv.fr/Publications/Espace-presse/Communiques-et-dossiers-de-presse-2021'], NOW()),
    ('allier.gouv.fr', 'Prefecture Allier', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.allier.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foncier-agricole-CDPENAF/Compensation-agricole-projets-d-amenagement', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Foncier-agricole-CDPENAF/Document-cadre-relatif-aux-installations-photovoltaiques', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction/Atlas-departemental/Energie', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction/Comment-amenager-durablement', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Environnement/Eau-et-milieux-aquatiques', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables', 'https://www.allier.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees/Dossiers-d-examen-au-cas-par-cas', 'https://www.allier.gouv.fr/Publications/Enquetes-et-consultations-publiques/Consultations-publiques-achevees/Centrales-photovoltaiques', 'https://www.allier.gouv.fr/Publications/Enquetes-et-consultations-publiques/Consultations-publiques-achevees/Eoliennes', 'https://www.allier.gouv.fr/Publications/Enquetes-et-consultations-publiques/Consultations-publiques-en-cours'], NOW()),
    ('alpes-de-haute-provence.gouv.fr', 'Prefecture Alpes-de-Haute-Provence', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.alpes-de-haute-provence.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement/Compensation-agricole/Etudes-prealables', 'https://www.alpes-de-haute-provence.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement/Energies-renouvelables', 'https://www.alpes-de-haute-provence.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Eau-et-milieux-aquatiques/Actes-administratifs-delivres', 'https://www.alpes-de-haute-provence.gouv.fr/Publications/Appels-a-projets-Consultations/Enquetes-publiques-autorisations-et-avis/Listes-des-communes-par-ordre-alphabetique', 'https://www.alpes-de-haute-provence.gouv.fr/Publications/Appels-a-projets-Consultations/Participation-du-public-environnement/Document-cadre-04-PV-sol/Consultation-en-cours', 'https://www.alpes-de-haute-provence.gouv.fr/Publications/Publications-administratives-et-legales/Recueil-des-Actes-Administratifs'], NOW()),
    ('hautes-alpes.gouv.fr', 'Prefecture Hautes-Alpes', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Agriculture-et-Foret/Agriculture/Foncier-agricole/Compensation-collective-agricole', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-logement/Droit-d-initiative', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Avis-Autorite-Environnementale', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Energies-renouvelables/Etat-des-lieux-et-recommandations', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Energies-renouvelables/Loi-d-acceleration-pour-les-energies-renouvelables-et-zones-d-acceleration', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Regime-de-la-declaration/Preuves-de-depot-de-declaration-et-arretes-prefectoraux', 'https://www.hautes-alpes.gouv.fr/Actions-de-l-Etat/Environnement-bruit-risques-naturels-et-technologiques/Participation-du-public-Enquetes-publiques/Enquetes-environnementales', 'https://www.hautes-alpes.gouv.fr/Publications/Catalogue-des-ressources-d-ingenierie-locale/Par-structure/IT05-Ingenierie-territoriale-Hautes-Alpes', 'https://www.hautes-alpes.gouv.fr/Publications/Catalogue-des-ressources-d-ingenierie-locale/Par-structure/SyME05-Syndicat-mixte-d-energie', 'https://www.hautes-alpes.gouv.fr/Publications/Donnees-territoriales-cartographiques/Cartographies-interactives'], NOW()),
    ('alpes-maritimes.gouv.fr', 'Prefecture Alpes-Maritimes', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.alpes-maritimes.gouv.fr/Publications/Enquetes-publiques/Autorisation-de-defrichement'], NOW()),
    ('ardeche.gouv.fr', 'Prefecture Ardeche', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.ardeche.gouv.fr/Actions-de-l-Etat/Agriculture/Foncier/Urbanisme-en-zone-agricole', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Avis-de-l-autorite-environnementale', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-Refus/SAS-Parc-eolien-de-Pratauberat', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-de-prescriptions-complementaires', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-de-prescriptions-speciales', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Decisions/AP-modificatif', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Enquetes-publiques-procedure-d-autorisation/Enquetes-publiques-terminees', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Procedure-de-declaration/Preuve-de-depot', 'https://www.ardeche.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Transition-energetique/Le-developpement-de-l-eolien/L-eolien-pourquoi-et-comment', 'https://www.ardeche.gouv.fr/Pied-de-page/Enquetes-et-consultations-publiques-hors-ICPE/Enquetes-et-consultations-en-cours', 'https://www.ardeche.gouv.fr/Publications/Enquetes-et-consultations-publiques-hors-ICPE/Consultations-publiques/En-cours', 'https://www.ardeche.gouv.fr/Publications/Enquetes-et-consultations-publiques-hors-ICPE/Enquetes-publiques/En-cours', 'https://www.ardeche.gouv.fr/Publications/Enquetes-et-consultations-publiques-hors-ICPE/Enquetes-publiques/Terminees'], NOW()),
    ('ardennes.gouv.fr', 'Prefecture Ardennes', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Energie-Climat/Les-energies-renouvelables/Le-plan-de-paysage-eolien', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Energie-Climat/Les-energies-renouvelables/Le-pole-Energies-renouvelables-des-Ardennes', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Enquetes-publiques-et-consultations-du-public/Hors-ICPE-loi-sur-l-eau.-urbanisme', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Enquetes-publiques-et-consultations-du-public/Pour-les-ICPE', 'https://www.ardennes.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees-pour-la-protection-de-l-environnement-ICPE/Cas-par-Cas'], NOW()),
    ('ariege.gouv.fr', 'Prefecture Ariege', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.ariege.gouv.fr/Actions-de-l-Etat/Agriculture/Compensation-collective-agricole', 'https://www.ariege.gouv.fr/Actions-de-l-Etat/Environnement-biodiversite/Installations-classees-Mines-Carrieres/Arretes-prefectoraux-d-autorisation-et-complementaires', 'https://www.ariege.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique/Favoriser-le-developpement-des-energies-renouvelables', 'https://www.ariege.gouv.fr/Publications/Consultations-du-public/Consultations-du-public-direction-departementale-des-territoires/Urbanisme-ADS', 'https://www.ariege.gouv.fr/Publications/Enquetes-publiques/EOLIEN', 'https://www.ariege.gouv.fr/Publications/Enquetes-publiques/URBANISME', 'https://www.ariege.gouv.fr/Publications/Espace-presse/Communiques-de-presse/Tournee-de-prevention-Bon-ete-bons-reflexes-sante'], NOW()),
    ('aube.gouv.fr', 'Prefecture Aube', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.aube.gouv.fr/Publications/Amenagement-du-territoire-Environnement-Developpement-durable/ICPE-Installations-Classees-pour-la-Protection-de-l-Environnement/Publications-reglementaires-arretes-ICPE-preuves-de-depot-mises-en-demeure-et-sanctions/Installations-classees-arretes-d-enregistrement', 'https://www.aube.gouv.fr/Publications/Amenagement-du-territoire-Environnement-Developpement-durable/ICPE-Installations-Classees-pour-la-Protection-de-l-Environnement/Publications-reglementaires-arretes-ICPE-preuves-de-depot-mises-en-demeure-et-sanctions/Installations-classees-autorisations-uniques-et-environnementales', 'https://www.aube.gouv.fr/Publications/Consultations-du-public-declarations-d-intention-et-commissaire-enqueteur/Consultations-du-public-organisees-par-l-Etat/SAINT-OULPH-et-ETRELLES-s-AUBE-Societe-SAINT-OULPH-ETRELLES-ENERGIE-Projet-de-parc-eolien', 'https://www.aube.gouv.fr/Publications/Consultations-du-public-declarations-d-intention-et-commissaire-enqueteur/Rapports-et-conclusions-des-commissaires-enqueteurs'], NOW()),
    ('aude.gouv.fr', 'Prefecture Aude', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2020', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2021', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2022', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2023/avril-mai-juin', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2023/janvier-fevrier-mars', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2024/Avril-Mai-Juin-Juillet', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction-et-habitat/Commission-Departementale-de-la-Preservation-des-Espaces-Naturel.-Agricole-et-Forestiers-CDPENAF/Mesures-de-compensation-collective-agricole/Etudes-prealables-et-avis-du-Prefet/2024/Janvier-Fevrier-Mars', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Environnement-et-Developpement-durable/Energies-Renouvelables/La-planification-des-energies-renouvelables', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Arretes-prefectoraux-d-autorisation-arretes-complementaires', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Les-dossiers-ICPE-complets-a-consulter/Les-Parcs-Eoliens', 'https://www.aude.gouv.fr/Actions-de-l-Etat/Environnement-eau-foret-chasse-risques-naturels-technologiques/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Les-enquetes-publiques-et-consultations-du-public-dossiers-complets-hors-ICPE/Photovoltaique'], NOW()),
    ('aveyron.gouv.fr', 'Prefecture Aveyron', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.aveyron.gouv.fr/Actions-de-l-Etat/Agriculture-et-foret/Foncier/Compensation-Agricole-Collective', 'https://www.aveyron.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique/Developpement-des-energies-renouvelables', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Enquetes-publiques/Cloturees/Autres-enquetes', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Enquetes-publiques/Cloturees/Installation-Classee-Pour-la-Protection-de-l-Environnement-ICPE', 'https://www.aveyron.gouv.fr/Publications/Consultations-du-public/Enquetes-publiques/EN-COURS', 'https://www.aveyron.gouv.fr/Publications/Decisions-administratives/ICPE/Arretes-prefectoraux', 'https://www.aveyron.gouv.fr/Publications/Decisions-administratives/ICPE/Preuves-de-depot-des-declarations', 'https://www.aveyron.gouv.fr/Publications/Decisions-administratives/Loi-sur-l-eau/Recepisses'], NOW()),
    ('bouches-du-rhone.gouv.fr', 'Prefecture Bouches-du-Rhone', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.bouches-du-rhone.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Preservation-des-espaces-agricoles-naturels-et-forestiers/Compensation-collective-agricole', 'https://www.bouches-du-rhone.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Transition-energetique-energies-renouvelables', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Enquetes-publiques-hors-ICPE', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Installations-Classees-soumises-a-autorisation-et-a-enregistrement-Carrieres-et-Geothermie', 'https://www.bouches-du-rhone.gouv.fr/Publications/Publications-environnementales/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Installations-Classees-soumises-a-declaration'], NOW()),
    ('calvados.gouv.fr', 'Prefecture Calvados', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.calvados.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire.-construction.-logement/Energies-renouvelables/Eolien', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Avis-de-l-Autorite-Environnementale', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Energies-renouvelables/Eolien-en-mer', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Demarches-declaration.-enregistrement.-autorisation/Procedure-d-installation-d-un-parc-eolien-terrestre', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/ARRETES-PREFECTORAUX-2024', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Arretes-prefectoraux/Arretes-prefectoraux-2025', 'https://www.calvados.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/ICPE/Installations-classees-industrielles/Enquete-publique-consultation-du-public-par-voie-electronique/2024', 'https://www.calvados.gouv.fr/Publications/Avis-et-consultation-du-public/Avis-enquete-publique/Les-avis-d-enquetes-publiques-en-cours', 'https://www.calvados.gouv.fr/Publications/Avis-et-consultation-du-public/Consultation-du-public/Les-consultations-en-cours'], NOW()),
    ('cantal.gouv.fr', 'Prefecture Cantal', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.cantal.gouv.fr/Action-de-l-Etat/Amenagement-du-Territoire-Construction/Transition-energetique-et-developpement-durable', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Energies-renouvelables/Les-parcs-eoliens', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Information-et-participation-du-public/Participation-du-public/Consultations', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Information-et-participation-du-public/Participation-du-public/Consultations-terminees', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Decisions-individuelles', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Preuves-de-depot/ANNEE-2024', 'https://www.cantal.gouv.fr/Action-de-l-Etat/Environnement/Installations-classees/Preuves-de-depot/ANNEE-2025'], NOW()),
    ('charente.gouv.fr', 'Prefecture Charente', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.charente.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-espaces-naturels/Preservation-des-espaces-naturels-agricoles-et-forestiers-ENAF', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Ambernac', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Brettes', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Brigueuil', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Champagne-Mouton', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Chasseneuil-sur-Bonnieure', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Confolens', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Saint-Fraigne', 'https://www.charente.gouv.fr/Actions-de-l-Etat/Environnement-Chasse-Eau-Risques/DUP-ICPE-IOTA/Xambes'], NOW()),
    ('charente-maritime.gouv.fr', 'Prefecture Charente-Maritime', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Agriculture-foret-et-developpement-rural/Agriculture/Agriculture-urbanisme-et-territoire', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-et-commissions-consultatives/Consultations-du-public/Consultations-parallelisees-en-cours-loi-industrie-verte', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-et-commissions-consultatives/Consultations-du-public/Enquetes-publiques-cloturees', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-et-commissions-consultatives/Consultations-du-public/Enquetes-publiques-en-cours', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Installation-Classee-pour-la-Protection-de-l-Environnement', 'https://www.charente-maritime.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Projet-eolien-en-mer'], NOW()),
    ('cher.gouv.fr', 'Prefecture Cher', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.cher.gouv.fr/Actions-de-l-Etat/Risques-PPR-DDRM-DICRIM-PCS-IAL-ICPE-PAPI-PGRI-RGA-termites-merules/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Decisions-implicites', 'https://www.cher.gouv.fr/Actions-de-l-Etat/Risques-PPR-DDRM-DICRIM-PCS-IAL-ICPE-PAPI-PGRI-RGA-termites-merules/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Declaration-ICPE', 'https://www.cher.gouv.fr/Publications/Enquetes-publiques/AOEP-Avis-d-ouverture-d-enquete-publique', 'https://www.cher.gouv.fr/Publications/Enquetes-publiques/ICPE-Enquetes-publiques-Consultations-du-public/ICPE-autorisation-dossiers-de-demande-d-autorisation-avis-d-enquete-publique-de-consultation-parallelisee-et-participation-du-public-par-voie-electronique', 'https://www.cher.gouv.fr/Publications/Enquetes-publiques/Rapport-Enquetes-publiques', 'https://www.cher.gouv.fr/Publications/Participation-du-public-projets-amenagement-ou-equipement-incidence-environnement-territoire'], NOW()),
    ('correze.gouv.fr', 'Prefecture Correze', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.correze.gouv.fr/Publications/Annonces-avis/Avis-et-Decisions-du-prefet-accord-accord-avec-reserves-refus-et-arretes-complementaires', 'https://www.correze.gouv.fr/Publications/Annonces-avis/Consultations-du-public/PARC-PHOTOVOLTAIQUE-Enquete-publique-du-16-12-2025-au-14-01-2026-Projet-sur-commune-d-Albussac'], NOW()),
    ('corse-du-sud.gouv.fr', 'Prefecture Corse-du-Sud', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.corse-du-sud.gouv.fr/Publications/Annonces-judiciaires-et-legales/Installations-classees-pour-la-protection-de-l-environnement-ICPE', 'https://www.corse-du-sud.gouv.fr/Publications/Consultation-du-public/Enquetes-publiques'], NOW()),
    ('haute-corse.gouv.fr', 'Prefecture Haute-Corse', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-corse.gouv.fr/Actions-de-l-Etat/Transition-ecologique-environnement-et-prevention-des-risques/Procedures-installations-classees-ICPE/Installations-soumises-a-declaration', 'https://www.haute-corse.gouv.fr/Publications/Appels-a-projets-Consultations-Enquetes-publiques/Consultations-publiques', 'https://www.haute-corse.gouv.fr/Publications/Appels-a-projets-Consultations-Enquetes-publiques/Enquetes-publiques/Enquetes-Environnement', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2024', 'https://www.haute-corse.gouv.fr/Publications/Publications-administratives-et-legales/Recueils-des-actes-administratifs/Recueils-des-actes-administratifs-2026'], NOW()),
    ('cote-dor.gouv.fr', 'Prefecture Cote-d''Or', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Agriculture.-foret-et-developpement-rural/Agriculture/Exploitations-agricoles-foncier-controle-des-structures/Etude-prealable-agricole-et-compensations-collectives-agricoles', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Eoliennes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Les-zones-d-acceleration-du-developpement-des-energies-renouvelables', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Photovoltaique', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/Avis-de-l-autorite-environnementale/Sur-plusieurs-communes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/Sur-plusieurs-communes', 'https://www.cote-dor.gouv.fr/Actions-de-l-Etat/Environnement/Toute-la-reglementation-environnementale/ICPE/Sur-plusieurs-departements'], NOW()),
    ('cotes-darmor.gouv.fr', 'Prefecture Cotes-d''Armor', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Energie/Photovoltaique', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Consultation-du-public-Art-L.181-10-1-du-CE-Loi-Industrie-Verte', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Enquetes-publiques-Archivees', 'https://www.cotes-darmor.gouv.fr/Actions-de-l-Etat/Environnement-Biodiversite-Foret-et-transition-energetique/Installations-classees-industrielles/Participation-du-public-par-voie-electronique-article-L-123-19-2-du-code-de-l-environnement', 'https://www.cotes-darmor.gouv.fr/Publications/Enquetes-publiques2/Projet-de-centrale-photovoltaique-au-sol-a-Plouguernevel'], NOW()),
    ('creuse.gouv.fr', 'Prefecture Creuse', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Eolien/Parcs-eoliens', 'https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Photovoltaique/Parcs-photovoltaiques', 'https://www.creuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Strategie-EnR-en-Creuse'], NOW()),
    ('dordogne.gouv.fr', 'Prefecture Dordogne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.dordogne.gouv.fr/Actions-de-l-Etat/Environnement-Eau-Biodiversite-Risques/Participation-du-public/Archives', 'https://www.dordogne.gouv.fr/Actions-de-l-Etat/Environnement-Eau-Biodiversite-Risques/Participation-du-public/Consultation-du-public', 'https://www.dordogne.gouv.fr/Actions-de-l-Etat/Transition-ecologique-energie-climat/Energies-renouvelables'], NOW()),
    ('doubs.gouv.fr', 'Prefecture Doubs', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.doubs.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-Construction-Logement-et-Transports/Amenagement-et-developpement-durables/Enquetes-publiques/Autres-enquetes', 'https://www.doubs.gouv.fr/Actions-de-l-Etat/Environnement/Climat-Air-Energie/Le-Pole-Energies-renouvelables-du-Doubs-Pole-EnR/Reunions-plenieres-du-pole-EnR'], NOW()),
    ('drome.gouv.fr', 'Prefecture Drome', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.drome.gouv.fr/Actions-de-l-Etat/Agriculture.-forets-et-developpement-rural/Agriculture/Foncier-agricole/Compensation-collective-agricole', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Environnement-eau-risques-naturels-et-technologiques/Environnement-eau/Installations-classees/ICPE-Declaration2/Preuves-de-depot-de-declaration', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique-Developpement-des-energies-renouvelables/Avis-sur-les-projets-en-cours-d-instruction', 'https://www.drome.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique-Developpement-des-energies-renouvelables/Energies-renouvelables/Photovoltaique', 'https://www.drome.gouv.fr/Pied-de-page/AEE-Avis-de-l-Autorite-Environnementale', 'https://www.drome.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-et-consultations-classees-par-ville', 'https://www.drome.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-et-consultations-en-cours'], NOW()),
    ('eure.gouv.fr', 'Prefecture Eure', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Consultations-enquetes-publiques-et-participation-du-public-par-voie-electronique-PPVE/Enquetes-publiques', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Consultations-enquetes-publiques-et-participation-du-public-par-voie-electronique-PPVE/PPVE', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Eolien', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Photovoltaique', 'https://www.eure.gouv.fr/Actions-de-l-Etat/Planification-ecologique/Zones-d-acceleration-des-Energies-Renouvelables-ZAEnR'], NOW()),
    ('eure-et-loir.gouv.fr', 'Prefecture Eure-et-Loir', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Climat-Air-Energie/Energies-renouvelables/IFER', 'https://www.eure-et-loir.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Installations-classees/Cas-par-Cas/DECISIONS-PRISES', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Consultation-du-Public-par-voie-electronique-L181-10-1-du-Code-de-l-Environnement/En-cours', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Consultation-du-Public-par-voie-electronique-L181-10-1-du-Code-de-l-Environnement/Terminees', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/En-cours', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2024', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2025', 'https://www.eure-et-loir.gouv.fr/Publications/Enquetes-Publiques-et-consultation-du-public/Enquetes-publiques/Terminees/2026'], NOW()),
    ('finistere.gouv.fr', 'Prefecture Finistere', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.finistere.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Les-centrales-photovoltaiques-au-sol', 'https://www.finistere.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Les-eoliennes', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Decisions-recentes-relatives-aux-autorisations-environnementales-et-aux-installations-classees', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Enquetes-publiques/Enquete-Publique-Unique-hydroliennes-et-parc-photovoltaique-a-OUESSANT', 'https://www.finistere.gouv.fr/Publications/Publications-legales/Participation-du-public-par-voie-electronique-PPVE'], NOW()),
    ('gard.gouv.fr', 'Prefecture Gard', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.gard.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Classement-des-ICPE-par-entreprises-regimes-autorisation-et-enregistrement', 'https://www.gard.gouv.fr/Publications/Consultation-du-public', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2023', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Archives-enquetes-publiques-publiees-entre-2013-et-2024/Enquetes-publiques-publiees-en-2024', 'https://www.gard.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-publiees-en-2025', 'https://www.gard.gouv.fr/Publications/Environnement/Participation-du-public-aux-decisions-ayant-une-incidence-sur-l-environnement/Procedures-en-cours'], NOW()),
    ('haute-garonne.gouv.fr', 'Prefecture Haute-Garonne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-garonne.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Climat-air-energie/Le-pole-energies-renouvelables', 'https://www.haute-garonne.gouv.fr/Publications/Declarations-d-intention-enquetes-publiques-et-avis-de-l-autorite-environnementale/Urbanisme/Enquetes-publiques-achevees'], NOW()),
    ('gers.gouv.fr', 'Prefecture Gers', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.gers.gouv.fr/Actions-de-l-Etat/Agriculture/La-compensation-collective-agricole/Avis-du-Prefet-sur-les-etudes-prealables', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Environnement/AOEP-Avis-d-ouverture-d-enquetes-publiques/Enquetes-cloturees', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Environnement/AOEP-Avis-d-ouverture-d-enquetes-publiques/Enquetes-en-cours', 'https://www.gers.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-energetique/Energies-renouvelables', 'https://www.gers.gouv.fr/Publications/Avis-de-l-autorite-environnementale-et-cas-par-cas-hors-CPE'], NOW()),
    ('gironde.gouv.fr', 'Prefecture Gironde', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.gironde.gouv.fr/Publications/Publications-legales/Enquetes-publiques-consultations-du-public-declarations-d-intention-decisions-examen-cas-par-cas/Enquete-publique-Consultation-du-public-2022'], NOW()),
    ('herault.gouv.fr', 'Prefecture Herault', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.herault.gouv.fr/Actions-de-l-Etat/Transition-energetique/Vous-etes-un-particulier', 'https://www.herault.gouv.fr/Publications/Consultation-du-public/ENQUETES-PUBLIQUES2/PHOTOVOLTAIQUE', 'https://www.herault.gouv.fr/Publications/Consultation-du-public/INSTALLATIONS-CLASSEES/PARCS-EOLIENS'], NOW()),
    ('ille-et-vilaine.gouv.fr', 'Prefecture Ille-et-Vilaine', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.ille-et-vilaine.gouv.fr/Actions-de-l-Etat/Environnement-et-energie/L-energie', 'https://www.ille-et-vilaine.gouv.fr/Publications/Consultations-publiques-et-concertations-prealables/Consultations-Publiques-Environnement/Consultations-publiques-environnementales-archivees/2024', 'https://www.ille-et-vilaine.gouv.fr/Publications/Consultations-publiques-et-concertations-prealables/Consultations-Publiques-Environnement/Consultations-publiques-environnementales-archivees/2025', 'https://www.ille-et-vilaine.gouv.fr/Publications/Publications-legales/Enquetes-publiques'], NOW()),
    ('indre.gouv.fr', 'Prefecture Indre', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.indre.gouv.fr/Actions-de-l-Etat/Environnement/Transition-energetique', 'https://www.indre.gouv.fr/Publications/Enquetes-Publiques-autre-que-ICPE/IMPLANTATION-D-UNE-CENTRALE-PHOTOVOLTAIQUE-AU-SOL-D-UNE-SURFACE-DE-15-51-au-lieu-dit-Prise-des-Tardets-sur-la-commune-de-BELABRE'], NOW()),
    ('indre-et-loire.gouv.fr', 'Prefecture Indre-et-Loire', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables', 'https://www.indre-et-loire.gouv.fr/Actions-de-l-Etat/Risques-naturels-et-technologiques/Installations-classees-pour-la-protection-de-l-environnement/Arretes-d-autorisation-d-enregistrement-de-refus-et-preuves-de-depot-de-teledeclaration', 'https://www.indre-et-loire.gouv.fr/Publications/Demandes-d-examen-au-cas-par-cas', 'https://www.indre-et-loire.gouv.fr/Publications/Enquetes-publiques-en-cours', 'https://www.indre-et-loire.gouv.fr/Publications/Rapports-et-conclusions-des-enquetes-publiques'], NOW()),
    ('isere.gouv.fr', 'Prefecture Isere', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.isere.gouv.fr/Actions-de-l-Etat/Acceleration-de-la-transition-ecologique/Transition-energetique/Energies-renouvelables/Vous-etes-une-collectivite', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2024', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2025', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Enquetes-publiques/Enquetes-publiques-2026', 'https://www.isere.gouv.fr/Publications/Mises-a-disposition-Consultations-enquetes-publiques-concertations-prealables-declarations-de-projets/Participation-du-public-par-voie-electronique-PPVE/PPVE-2024'], NOW()),
    ('jura.gouv.fr', 'Prefecture Jura', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.jura.gouv.fr/Actions-de-l-Etat/Environnement/Participation-et-consultation-du-public/Au-titre-du-code-de-l-environnement/Participation-et-consultation-du-public-terminee', 'https://www.jura.gouv.fr/Publications/Annonces-avis/Enquetes-publiques/Divers/Parc-Photovoltaique-CRAMANS', 'https://www.jura.gouv.fr/Publications/Annonces-avis/Mise-a-disposition-du-public'], NOW()),
    ('landes.gouv.fr', 'Prefecture Landes', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.landes.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique', 'https://www.landes.gouv.fr/Publications/Consultations-du-public', 'https://www.landes.gouv.fr/Publications/Publications-legales/Enquetes-publiques'], NOW()),
    ('loir-et-cher.gouv.fr', 'Prefecture Loir-et-Cher', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.loir-et-cher.gouv.fr/Actions-de-l-Etat/Developpement-durable-et-cadre-de-vie/Energie-Air-et-Climat/Energies-renouvelables', 'https://www.loir-et-cher.gouv.fr/Publications/Enquetes-publiques', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2024', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2025', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Enquetes-publiques/2026', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Installations-classees/Arretes-prefectoraux', 'https://www.loir-et-cher.gouv.fr/Publications/Publications-legales/Installations-classees/Installations-relevant-du-regime-de-la-declaration2'], NOW()),
    ('loire.gouv.fr', 'Prefecture Loire', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.loire.gouv.fr/Actions-de-l-Etat/Environnement/Climat-et-energies/Les-energies-renouvelables/Les-differentes-sources', 'https://www.loire.gouv.fr/Publications/Consultation-du-public', 'https://www.loire.gouv.fr/Publications/Enquetes-publiques/Photovoltaique-Eolien'], NOW()),
    ('haute-loire.gouv.fr', 'Prefecture Haute-Loire', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-loire.gouv.fr/Actions-de-l-Etat/Agriculture/Gestion-du-foncier-agricole/Compensations-collectives-agricoles/Avis-du-Prefet-sur-les-etudes-prealables', 'https://www.haute-loire.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Installations-classees/Regime-d-autorisation', 'https://www.haute-loire.gouv.fr/Publications/Enquetes-publiques-Etat/Autres-enquetes-publiques'], NOW()),
    ('loire-atlantique.gouv.fr', 'Prefecture Loire-Atlantique', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Developpement-durable-et-mobilite/Energies-renouvelables/Solaire-et-photovoltaique', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public-aux-decisions-ayant-une-incidence-sur-l-environnement/Consultations-terminees', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Installations-classees-ICPE2/Eolien', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Participation-du-public-par-voie-electronique-PPVE', 'https://www.loire-atlantique.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-administratives-commissions/Photovoltaique'], NOW()),
    ('loiret.gouv.fr', 'Prefecture Loiret', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.loiret.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Transition-energetique2/Energies-renouvelables-EnR', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2024', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2025', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-closes/2026', 'https://www.loiret.gouv.fr/Publications/Enquetes-publiques-et-consultations-du-public/Enquetes-en-cours-et-a-venir'], NOW()),
    ('lot.gouv.fr', 'Prefecture Lot', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.lot.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-ecologie-et-logement/Projets-energies-renouvelables/2-les-projets-en-cours', 'https://www.lot.gouv.fr/Actions-de-l-Etat/Environnement.-risques-naturels-et-technologiques/Photovoltaique', 'https://www.lot.gouv.fr/Publications/Participations-du-public/Anciennes-participations-du-public/Enquetes-publiques-2024'], NOW()),
    ('lot-et-garonne.gouv.fr', 'Prefecture Lot-et-Garonne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.lot-et-garonne.gouv.fr/Actions-de-l-Etat/Agriculture/Etudes-prealables-agricoles', 'https://www.lot-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-Public', 'https://www.lot-et-garonne.gouv.fr/Publications/Publications-legales/Avis-d-ouverture-d-enquete-publique', 'https://www.lot-et-garonne.gouv.fr/Publications/Publications-legales/ICPE/Declarations-Preuves-de-depot'], NOW()),
    ('lozere.gouv.fr', 'Prefecture Lozere', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.lozere.gouv.fr/Actions-de-l-Etat/Environnement-Risques-naturels-et-technologiques/Consultation-du-public', 'https://www.lozere.gouv.fr/Actions-de-l-Etat/Environnement-Risques-naturels-et-technologiques/Energies-renouvelables/Energie-eolienne', 'https://www.lozere.gouv.fr/Publications/Enquetes-publiques-Participation-du-public/Enquetes-publiques-environnementales/Enquetes-publiques-environementales', 'https://www.lozere.gouv.fr/Publications/Enquetes-publiques-Participation-du-public/Enquetes-publiques-environnementales/Installations-classees-pour-la-protection-de-l-environnement-autorisation'], NOW()),
    ('maine-et-loire.gouv.fr', 'Prefecture Maine-et-Loire', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.maine-et-loire.gouv.fr/Actions-de-l-Etat/Transition-Ecologique/Energies-Renouvelables-EnR/Les-differentes-filieres/Eolien', 'https://www.maine-et-loire.gouv.fr/Publications/Consultation-du-public/Consultations-en-cours/ICPE', 'https://www.maine-et-loire.gouv.fr/Publications/Enquetes-publiques/Installation-Classee-pour-la-Protection-de-l-Environnement-ICPE/Annee-2024', 'https://www.maine-et-loire.gouv.fr/Publications/Enquetes-publiques/Installation-Classee-pour-la-Protection-de-l-Environnement-ICPE/Annee-2025'], NOW()),
    ('manche.gouv.fr', 'Prefecture Manche', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.manche.gouv.fr/Publications/Annonces-et-avis/Arretes/Environnement', 'https://www.manche.gouv.fr/Publications/Annonces-et-avis/Consultations-publiques/Especes-protegees', 'https://www.manche.gouv.fr/Publications/Annonces-et-avis/Enquetes-publiques'], NOW()),
    ('marne.gouv.fr', 'Prefecture Marne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.marne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-Classees-pour-la-Protection-de-l-Environnement-ICPE/Dossiers-ICPE-Autorisation/Dossiers-ICPE-Autorisation-Domaine-eolien', 'https://www.marne.gouv.fr/Publications/Appels-a-projets-consultations/Enquetes-publiques/Autres-enquetes', 'https://www.marne.gouv.fr/Publications/Appels-a-projets-consultations/Enquetes-publiques/Enquete-publique-Urbanisme'], NOW()),
    ('haute-marne.gouv.fr', 'Prefecture Haute-Marne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-marne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme/Energies-renouvelables/Les-comites-consultatifs-sur-les-projets-eoliens-et-photovoltaiques-au-sol', 'https://www.haute-marne.gouv.fr/Actions-de-l-Etat/Risques-naturels-et-technologiques/Installations-classees-pour-la-protection-de-l-environnement/Autorisations-environnementales/Dossiers-autorisations-environnementales-Haute-Marne', 'https://www.haute-marne.gouv.fr/Publications/Enquetes-publiques/Construction-d-une-centrale-photovoltaique-au-sol-a-Vesaignes-sur-Marne-SAS-MANA-VSM'], NOW()),
    ('mayenne.gouv.fr', 'Prefecture Mayenne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.mayenne.gouv.fr/Actions-de-l-Etat/Energie-et-Climat/Energies-renouvelables', 'https://www.mayenne.gouv.fr/Actions-de-l-Etat/Environnement-eau-et-biodiversite/Enquetes-publiques-hors-ICPE-Commissaires-enqueteurs/Divers', 'https://www.mayenne.gouv.fr/Actions-de-l-Etat/Environnement-eau-et-biodiversite/Installations-classees/Installations-classees-industrielles-carrieres/Autorisation'], NOW()),
    ('meurthe-et-moselle.gouv.fr', 'Prefecture Meurthe-et-Moselle', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.meurthe-et-moselle.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire/Commission-Departementale-de-la-Preservation-des-Espaces-Naturels-Agricoles-et-Forestiers/Etude-prealable-agricole-et-mesures-de-compensation-agricole-collective2', 'https://www.meurthe-et-moselle.gouv.fr/Actions-de-l-Etat/Enquetes-et-consultations-publiques/Consultations-publiques2', 'https://www.meurthe-et-moselle.gouv.fr/Actions-de-l-Etat/Enquetes-et-consultations-publiques/Enquetes-publiques/Consulter-les-enquetes-publiques-en-cours'], NOW()),
    ('meuse.gouv.fr', 'Prefecture Meuse', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/L-energie-eolienne', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/ICPE/Eoliennes', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public/Consultations-en-cours-ou-a-venir', 'https://www.meuse.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public/Suites-des-consultations-rapports-d-enquetes-et-decisions'], NOW()),
    ('morbihan.gouv.fr', 'Prefecture Morbihan', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.morbihan.gouv.fr/Actions-de-l-Etat/Environnement-et-developpement-durable/Energies/La-loi-d-acceleration-de-la-production-d-energies-renouvelables', 'https://www.morbihan.gouv.fr/Publications/Installations-classees-ICPE-actes-delivres/Arretes-d-autorisation-de-refus-et-de-prescriptions-complementaires/BULEON', 'https://www.morbihan.gouv.fr/Publications/Participation-du-public/Consultations-publiques-terminees/Installations-photovoltaiques-au-sol', 'https://www.morbihan.gouv.fr/Publications/Participation-du-public/Enquetes-publiques-terminees'], NOW()),
    ('moselle.gouv.fr', 'Prefecture Moselle', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.moselle.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/Accompagnement-des-porteurs-de-projets', 'https://www.moselle.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/Planification-des-energies-renouvelables/Zones-d-acceleration-des-energies-renouvelables', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Metz', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Arrondissement-de-Sarreguemines', 'https://www.moselle.gouv.fr/Publications/Publicite-legale-installations-classees-et-hors-installations-classees/Autorite-environnementale'], NOW()),
    ('nievre.gouv.fr', 'Prefecture Nievre', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.nievre.gouv.fr/Actions-de-l-Etat/Agriculture/2-Structures-des-exploitations-et-gestion-du-foncier2/CDPENAF/Compensation-collective/Etudes-prealables-et-avis-rendus', 'https://www.nievre.gouv.fr/Actions-de-l-Etat/Transition-energetique', 'https://www.nievre.gouv.fr/Publications/Consultation-et-participation-publique', 'https://www.nievre.gouv.fr/Publications/Enquetes-publiques-Etat'], NOW()),
    ('nord.gouv.fr', 'Prefecture Nord', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Les-projets-photovoltaiques', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Permis/Permis-de-construire-2024/Construction-d-une-centrale-photovoltaique-au-sol-sur-la-commune-de-Wahagnies', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-participation-du-public/Permis/Permis-de-construire-2025', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2024', 'https://www.nord.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Installations-eoliennes/Autorisations/Autorisations-2025'], NOW()),
    ('oise.gouv.fr', 'Prefecture Oise', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.oise.gouv.fr/Actions-de-l-Etat/Agriculture/Commission-departementale-de-preservation-des-espaces-naturels-agricoles-et-forestiers-CDPENAF/La-compensation-collective-agricole/Avis-de-la-CDPENAF-et-du-Prefet-sur-les-etudes-prealables-agricoles', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Transition-Ecologique-et-Energetique/Document-cadre-photovoltaique', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Amenagement-durable-du-territoire/Transition-Ecologique-et-Energetique/Energies-renouvelables/Guichet-unique-de-l-energie/Concertation-dans-le-cadre-des-projets-Photovoltaiques', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees/Par-arretes', 'https://www.oise.gouv.fr/Actions-de-l-Etat/Environnement/Les-installations-classees/Par-enquete-publique/Archives-EP-anterieures-a-2016'], NOW()),
    ('orne.gouv.fr', 'Prefecture Orne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Protection-de-l-environnement/Enquetes-publiques.-participation-et-consultation-du-public/Rapports-et-Conclusions-des-commissaires-enqueteurs', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Photovoltaique/Les-projets-de-centrales-photovoltaiques-dans-l-Orne/RAI-Societe-Le-Val-Solaire', 'https://www.orne.gouv.fr/Actions-de-l-Etat/Environnement.-transition-energetique-et-prevention-des-risques/Transition-energetique-bas-carbone/Energies-renouvelables/Photovoltaique/Les-projets-de-centrales-photovoltaiques-dans-l-Orne/SAINTE-SCOLASSE-SUR-SARTHE-le-projet-de-centrale-photovoltaique'], NOW()),
    ('pas-de-calais.gouv.fr', 'Prefecture Pas-de-Calais', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.pas-de-calais.gouv.fr/Actions-de-l-Etat/Environnement-developpement-durable/Installations-classees', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Enquetes-publiques/EOLIENNES', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Enquetes-publiques/Permis-de-construire', 'https://www.pas-de-calais.gouv.fr/Publications/Consultation-du-public/Participation-du-public-par-voie-electronique'], NOW()),
    ('puy-de-dome.gouv.fr', 'Prefecture Puy-de-Dome', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Autorisations-environnementales/Dossiers-autorisations-environnementales-Puy-de-Dome', 'https://www.puy-de-dome.gouv.fr/Actions-de-l-Etat/Environnement-eau-prevention-des-risques-energie/Photovoltaique', 'https://www.puy-de-dome.gouv.fr/Publications/Enquetes-publiques/2022'], NOW()),
    ('pyrenees-atlantiques.gouv.fr', 'Prefecture Pyrenees-Atlantiques', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-planification-et-urbanisme-construction/Enquetes-publiques/En-cours', 'https://www.pyrenees-atlantiques.gouv.fr/Actions-de-l-Etat/Cadre-de-vie-eau-environnement-et-risques-majeurs/Avis-de-l-autorite-environnementale'], NOW()),
    ('hautes-pyrenees.gouv.fr', 'Prefecture Hautes-Pyrenees', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.hautes-pyrenees.gouv.fr/Actions-de-l-Etat/Environnement-et-risques-majeurs/Energies-renouvelables', 'https://www.hautes-pyrenees.gouv.fr/Publications/Enquetes-publiques-et-consultation-du-Public/Enquetes-publiques/Historique-des-enquetes-cloturees/PC-Centrales-photovoltaiques-au-sol', 'https://www.hautes-pyrenees.gouv.fr/Publications/Enquetes-publiques-et-consultation-du-Public/Participation-du-public-par-voie-electronique-PPVE'], NOW()),
    ('pyrenees-orientales.gouv.fr', 'Prefecture Pyrenees-Orientales', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.pyrenees-orientales.gouv.fr/Actions-de-l-Etat/Environnement-eau-risques-naturels-et-technologiques/Energies-renouvelables/Planifier-les-energies-renouvelables/Document-cadre-pour-les-installations-photovoltaiques-sur-terrains-agricoles-naturels-et-forestiers', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Enquetes-publiques-Photovoltaique/Perpignan-Mas-Romeu-ARKOLIA2', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/Etudes-prealables-agricoles', 'https://www.pyrenees-orientales.gouv.fr/Publications/Enquetes-publiques-et-autres-procedures/ICPE-Installations-Classees-Protection-Environnement-soumises-a-autorisation'], NOW()),
    ('bas-rhin.gouv.fr', 'Prefecture Bas-Rhin', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.bas-rhin.gouv.fr/Actions-de-l-Etat/Environnement/ICPE-Installations-classees-pour-la-protection-de-l-environnement/Liste-des-ICPE-soumises-a-autorisation', 'https://www.bas-rhin.gouv.fr/Actions-de-l-Etat/Environnement/Photovoltaique', 'https://www.bas-rhin.gouv.fr/Publications/Consultations-du-public'], NOW()),
    ('haut-rhin.gouv.fr', 'Prefecture Haut-Rhin', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haut-rhin.gouv.fr/Actions-de-l-Etat/Environnement/Sobriete-energetique-et-Transition-ecologique', 'https://www.haut-rhin.gouv.fr/Publications/Rapports-d-activite-des-services-de-l-Etat/Rapport-d-activite-2024-des-services-de-l-Etat/Accelerer-la-transition-ecologique-dans-le-Haut-Rhin'], NOW()),
    ('rhone.gouv.fr', 'Prefecture Rhone', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', NULL, NULL),
    ('haute-saone.gouv.fr', 'Prefecture Haute-Saone', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement/Portail-energies-renouvelables', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Enquetes-publiques/Centrales-photovoltaiques', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Enquetes-publiques/Eoliennes', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Information-et-consultation-du-public/Participation-du-public-par-voie-electronique', 'https://www.haute-saone.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Eoliennes'], NOW()),
    ('saone-et-loire.gouv.fr', 'Prefecture Saone-et-Loire', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Agriculture/Foncier/Compensation-collective-agricole/Etudes-prealables', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-urbanisme-construction-habitat/Energies-renouvelables', 'https://www.saone-et-loire.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Decisions-administratives-individuelles/Decisions-IPCE'], NOW()),
    ('sarthe.gouv.fr', 'Prefecture Sarthe', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Installations-Classees/Autorisations-Enregistrements', 'https://www.sarthe.gouv.fr/Actions-de-l-Etat/Environnement-transition-energetique-et-prevention-des-risques/Les-energies-renouvelables', 'https://www.sarthe.gouv.fr/Publications/Consultations-et-enquetes-publiques'], NOW()),
    ('savoie.gouv.fr', 'Prefecture Savoie', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.savoie.gouv.fr/Actions-de-l-Etat/Paysages-environnement-risques-naturels-et-technologiques/Environnement/Eau-foret-biodiversite/Avis-d-enquetes-publiques-Consultations-du-public-parallelisees-loi-industrie-verte', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Paysages-environnement-risques-naturels-et-technologiques/Environnement/Eau-foret-biodiversite/Rapports-de-commissaires-enqueteurs', 'https://www.savoie.gouv.fr/Actions-de-l-Etat/Transition-energetique-et-ecologique-amenagement-du-territoire-construction-logement/Transition-energetique-et-ecologique/Transition-energetique', 'https://www.savoie.gouv.fr/Publications/Enquetes-publiques'], NOW()),
    ('haute-savoie.gouv.fr', 'Prefecture Haute-Savoie', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-savoie.gouv.fr/Actions-de-l-Etat/Votre-departement/Energies-renouvelables', 'https://www.haute-savoie.gouv.fr/Publications/Actions-participatives/Droit-a-l-information-sur-l-environnement/2025'], NOW()),
    ('paris.gouv.fr', 'Prefecture Paris', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', NULL, NULL),
    ('seine-maritime.gouv.fr', 'Prefecture Seine-Maritime', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Energie/Energies-renouvelables/La-demarche-d-identification-des-zones-d-acceleration-des-energies-renouvelables-ZAEnR', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Consultations-du-public/00-ENREGISTREMENT-ICPE/2024/LUNERAY', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/INSTALLATIONS-CLASSEES-POUR-LA-PROTECTION-DE-L-ENVIRONNEMENT/AUZOUVILLE-SUR-SAANE', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/Permis-de-Construire/Projet-de-construction-d-une-centrale-photovoltaique-au-sol-a-Arelaune-en-Seine', 'https://www.seine-maritime.gouv.fr/Actions-de-l-Etat/Environnement-et-prevention-des-risques/Enquetes-publiques-et-Consultations-du-public/Enquetes-publiques/Permis-de-Construire/Projet-de-construction-d-une-centrale-photovoltaique-au-sol-a-Oissel-sur-Seine'], NOW()),
    ('seine-et-marne.gouv.fr', 'Prefecture Seine-et-Marne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.seine-et-marne.gouv.fr/Actions-de-l-Etat/Climat-Energies/Transition-energetique-et-developpement-des-ENR', 'https://www.seine-et-marne.gouv.fr/Publications/Enquetes-publiques/LA-GRANDE-PAROISSE-PROJET-DE-CENTRALE-PHOTOVOLTAIQUE-FLOTTANTE'], NOW()),
    ('yvelines.gouv.fr', 'Prefecture Yvelines', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.yvelines.gouv.fr/Actions-de-l-Etat/Environnement/Environnement/Eau', 'https://www.yvelines.gouv.fr/Publications/Consultation-du-public', 'https://www.yvelines.gouv.fr/Publications/Enquetes-publiques/Urbanisme-Amenagement'], NOW()),
    ('deux-sevres.gouv.fr', 'Prefecture Deux-Sevres', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.deux-sevres.gouv.fr/Actions-de-l-Etat/Amenagement-territoire-construction-logement/Transition-ecologique-et-energetique/Energies-renouvelables', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/COURS', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/Enquete-publiques/Enquetes-publiques-departementales-et-arretes-d-autorisation/FOMPERRON', 'https://www.deux-sevres.gouv.fr/Publications/Annonces-et-avis/ICPE-Installations-Classees-pour-la-protection-de-l-Environnement/Preuve-de-depot-d-une-declaration'], NOW()),
    ('somme.gouv.fr', 'Prefecture Somme', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Autorite-environnementale-Avis-sur-les-evaluations-environnementales', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Environnement-Consultations-publiques', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Eolien', 'https://www.somme.gouv.fr/Actions-de-l-Etat/Environnement/Photovoltaique/Participations-du-public-par-voie-electronique-et-decisions'], NOW()),
    ('tarn.gouv.fr', 'Prefecture Tarn', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Avis-d-enquetes-publiques-de-consultation-du-public-et-declarations-d-intention-de-projet', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Avis-de-l-autorite-environnementale', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/Eau-Environnement-Prevention-des-risques/Environnement/Projets-impactant-l-environnement/Rapports-et-conclusions-commissaire-enqueteur', 'https://www.tarn.gouv.fr/Actions-de-l-Etat/La-planification-ecologique/Energies-renouvelables', 'https://www.tarn.gouv.fr/Publications/Participation-du-public/Participation-ou-consultation-du-Public/Procedures-terminees-et-resultats-de-la-participation'], NOW()),
    ('tarn-et-garonne.gouv.fr', 'Prefecture Tarn-et-Garonne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Energies-renouvelables/Cadre-general-de-mise-en-oeuvre-de-projets-d-energies-renouvelables', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-environnementales/Autorisation-environnementale-unique', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-environnementales/Enquetes-publiques-hors-ICPE', 'https://www.tarn-et-garonne.gouv.fr/Actions-de-l-Etat/Environnement/Procedures-environnementales/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Regime-d-autorisation'], NOW()),
    ('var.gouv.fr', 'Prefecture Var', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.var.gouv.fr/Actions-de-l-Etat/Agriculture/Compensation-collective-agricole', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Plans-et-projets-par-communes/Artigues', 'https://www.var.gouv.fr/Actions-de-l-Etat/Environnement/Plans-et-projets-d-amenagement-susceptibles-d-impacter-l-environnement/Plans-et-projets-par-communes/Meounes-Les-Montrieux', 'https://www.var.gouv.fr/Publications/Consultations-du-public', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-hors-ICPE', 'https://www.var.gouv.fr/Publications/Enquetes-publiques/Toutes-les-enquetes-publiques-cloturees/2024'], NOW()),
    ('vaucluse.gouv.fr', 'Prefecture Vaucluse', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.vaucluse.gouv.fr/Actions-de-l-Etat/Transition-ecologique-et-prevention-des-risques/Transition-energetique.-energies-renouvelables/Le-photovoltaique-en-Vaucluse', 'https://www.vaucluse.gouv.fr/Pied-de-page/AEE-Avis-de-l-Autorite-Environnementale/Liste-des-avis-de-l-autorite-environnementale', 'https://www.vaucluse.gouv.fr/Publications/Enquete-publique-Consultation-parallelisee-PPVE-Enregistrement-Hors-procedure-particuliere/Liste-des-enquetes-publiques/Centrale-photovotaique-a-Orange-ouverture-d-une-enquete-publique-du-02-12-2024-au-08-01-2025/Centrale-photovoltaique-a-Bollene-ouverture-d-une-enquete-publique-du-28-02-2024-au-29-03-2024'], NOW()),
    ('vendee.gouv.fr', 'Prefecture Vendee', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.vendee.gouv.fr/Actions-de-l-Etat/Energie', 'https://www.vendee.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-pour-la-protection-de-l-environnement-ICPE/Decisions-et-arretes', 'https://www.vendee.gouv.fr/Publications/Enquetes-publiques', 'https://www.vendee.gouv.fr/Publications/Participation-du-public/Participation-du-public-par-voie-electronique-declaration-d-intention'], NOW()),
    ('vienne.gouv.fr', 'Prefecture Vienne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.vienne.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-et-logement/Amenagement-du-territoire/Energies-renouvelables', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Consultation-du-public-Loi-industrie-verte-LIV/Centrale-photovoltaique', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Enquete-publique/Centrale-photovoltaique', 'https://www.vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees/Eoliennes'], NOW()),
    ('haute-vienne.gouv.fr', 'Prefecture Haute-Vienne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Etat-d-avancement-des-projets-EnR', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Energies-renouvelables/Photovoltaique/Avis-et-dossiers-d-enquete-publique-observations-electroniques-du-public', 'https://www.haute-vienne.gouv.fr/Actions-de-l-Etat/Environnement-risques-naturels-et-technologiques/Installations-classees-ICPE/Avis-et-dossier-d-enquetes-publiques-observations-du-public', 'https://www.haute-vienne.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-en-cours', 'https://www.haute-vienne.gouv.fr/Publications/Enquetes-publiques/Enquetes-publiques-passees/Autorisation-environnementale-et-permis-d-amenager-RN-147-2x2-voies'], NOW()),
    ('vosges.gouv.fr', 'Prefecture Vosges', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.vosges.gouv.fr/Actions-de-l-Etat/Amenagement-du-territoire-construction-logement-et-developpement-durable-et-fonds-europeens-Accessibilite/Eolien-photovoltaique', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Consultation-dematerialisee-du-public', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Installations-classees-soumises-a-autorisation', 'https://www.vosges.gouv.fr/Actions-de-l-Etat/Enquetes-publiques-et-consultations-du-public/Projet-photovoltaique'], NOW()),
    ('yonne.gouv.fr', 'Prefecture Yonne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Consultation', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Energie/Energie-renouvelable/Eolien', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Consultation-publique', 'https://www.yonne.gouv.fr/Actions-de-l-Etat/Environnement/Installations-classees-Loi-sur-l-eau-Declaration-d-Utilite-Publique-Photovoltaique/Enquetes-Publiques'], NOW()),
    ('territoire-de-belfort.gouv.fr', 'Prefecture Territoire de Belfort', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.territoire-de-belfort.gouv.fr/Actions-de-l-Etat/Ecologie/Energies-renouvelables', 'https://www.territoire-de-belfort.gouv.fr/Actions-de-l-Etat/Environnement/Participation-du-public-consultations-et-enquetes-publiques/Participation-du-public-consultations-et-enquetes-publiques-closes'], NOW()),
    ('essonne.gouv.fr', 'Prefecture Essonne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', NULL, NULL),
    ('hauts-de-seine.gouv.fr', 'Prefecture Hauts-de-Seine', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.hauts-de-seine.gouv.fr/Publications/Consultations-publiques-et-concertations-prealables'], NOW()),
    ('seine-saint-denis.gouv.fr', 'Prefecture Seine-Saint-Denis', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', NULL, NULL),
    ('val-de-marne.gouv.fr', 'Prefecture Val-de-Marne', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', ARRAY['https://www.val-de-marne.gouv.fr/Publications/Enquetes-publiques-et-concertations-prealables'], NOW()),
    ('val-doise.gouv.fr', 'Prefecture Val-d''Oise', 'prefecture', 'reglementaire',
     TRUE, 0.95, 0.75, 0.95, 0.40,
     'crawl_index', NULL, NULL)
ON CONFLICT (domain) DO NOTHING;

-- ==============================================================================
-- COVERAGE DEPARTEMENTALE DES 96 PREFECTURES
-- ==============================================================================
INSERT INTO news.source_coverage (source_id, niveau, region_name, dept_code)
SELECT s.id, 'departemental', NULL, d.dept_code
FROM news.sources s
JOIN (VALUES
    ('ain.gouv.fr', '01'), ('aisne.gouv.fr', '02'), ('allier.gouv.fr', '03'),
    ('alpes-de-haute-provence.gouv.fr', '04'), ('hautes-alpes.gouv.fr', '05'),
    ('alpes-maritimes.gouv.fr', '06'), ('ardeche.gouv.fr', '07'),
    ('ardennes.gouv.fr', '08'), ('ariege.gouv.fr', '09'), ('aube.gouv.fr', '10'),
    ('aude.gouv.fr', '11'), ('aveyron.gouv.fr', '12'),
    ('bouches-du-rhone.gouv.fr', '13'), ('calvados.gouv.fr', '14'),
    ('cantal.gouv.fr', '15'), ('charente.gouv.fr', '16'),
    ('charente-maritime.gouv.fr', '17'), ('cher.gouv.fr', '18'),
    ('correze.gouv.fr', '19'), ('corse-du-sud.gouv.fr', '2A'),
    ('haute-corse.gouv.fr', '2B'), ('cote-dor.gouv.fr', '21'),
    ('cotes-darmor.gouv.fr', '22'), ('creuse.gouv.fr', '23'),
    ('dordogne.gouv.fr', '24'), ('doubs.gouv.fr', '25'), ('drome.gouv.fr', '26'),
    ('eure.gouv.fr', '27'), ('eure-et-loir.gouv.fr', '28'),
    ('finistere.gouv.fr', '29'), ('gard.gouv.fr', '30'),
    ('haute-garonne.gouv.fr', '31'), ('gers.gouv.fr', '32'),
    ('gironde.gouv.fr', '33'), ('herault.gouv.fr', '34'),
    ('ille-et-vilaine.gouv.fr', '35'), ('indre.gouv.fr', '36'),
    ('indre-et-loire.gouv.fr', '37'), ('isere.gouv.fr', '38'),
    ('jura.gouv.fr', '39'), ('landes.gouv.fr', '40'),
    ('loir-et-cher.gouv.fr', '41'), ('loire.gouv.fr', '42'),
    ('haute-loire.gouv.fr', '43'), ('loire-atlantique.gouv.fr', '44'),
    ('loiret.gouv.fr', '45'), ('lot.gouv.fr', '46'),
    ('lot-et-garonne.gouv.fr', '47'), ('lozere.gouv.fr', '48'),
    ('maine-et-loire.gouv.fr', '49'), ('manche.gouv.fr', '50'),
    ('marne.gouv.fr', '51'), ('haute-marne.gouv.fr', '52'),
    ('mayenne.gouv.fr', '53'), ('meurthe-et-moselle.gouv.fr', '54'),
    ('meuse.gouv.fr', '55'), ('morbihan.gouv.fr', '56'), ('moselle.gouv.fr', '57'),
    ('nievre.gouv.fr', '58'), ('nord.gouv.fr', '59'), ('oise.gouv.fr', '60'),
    ('orne.gouv.fr', '61'), ('pas-de-calais.gouv.fr', '62'),
    ('puy-de-dome.gouv.fr', '63'), ('pyrenees-atlantiques.gouv.fr', '64'),
    ('hautes-pyrenees.gouv.fr', '65'), ('pyrenees-orientales.gouv.fr', '66'),
    ('bas-rhin.gouv.fr', '67'), ('haut-rhin.gouv.fr', '68'),
    ('rhone.gouv.fr', '69'), ('haute-saone.gouv.fr', '70'),
    ('saone-et-loire.gouv.fr', '71'), ('sarthe.gouv.fr', '72'),
    ('savoie.gouv.fr', '73'), ('haute-savoie.gouv.fr', '74'),
    ('paris.gouv.fr', '75'), ('seine-maritime.gouv.fr', '76'),
    ('seine-et-marne.gouv.fr', '77'), ('yvelines.gouv.fr', '78'),
    ('deux-sevres.gouv.fr', '79'), ('somme.gouv.fr', '80'),
    ('tarn.gouv.fr', '81'), ('tarn-et-garonne.gouv.fr', '82'),
    ('var.gouv.fr', '83'), ('vaucluse.gouv.fr', '84'), ('vendee.gouv.fr', '85'),
    ('vienne.gouv.fr', '86'), ('haute-vienne.gouv.fr', '87'),
    ('vosges.gouv.fr', '88'), ('yonne.gouv.fr', '89'),
    ('territoire-de-belfort.gouv.fr', '90'), ('essonne.gouv.fr', '91'),
    ('hauts-de-seine.gouv.fr', '92'), ('seine-saint-denis.gouv.fr', '93'),
    ('val-de-marne.gouv.fr', '94'), ('val-doise.gouv.fr', '95')
) AS d(domain, dept_code) ON s.domain = d.domain
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- SEED : couverture geographique des sources non-prefecture
-- ==============================================================================

-- National
INSERT INTO news.source_coverage (source_id, niveau)
SELECT id, 'national'
FROM news.sources
WHERE source_type IN ('officiel', 'enquete_publique', 'infrastructure',
                      'open_data', 'presse_specialisee', 'developer')
ON CONFLICT DO NOTHING;

-- Regional : presse locale
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

-- Presse et EP : bonne affinite photovoltaique et agrivoltaique
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'photovoltaique', 0.80
FROM news.sources
WHERE source_type IN ('presse_locale', 'presse_specialisee', 'officiel', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'agrivoltaique', 0.75
FROM news.sources
WHERE source_type IN ('presse_locale', 'presse_specialisee', 'officiel', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'eolien', 0.80
FROM news.sources
WHERE source_type IN ('presse_locale', 'presse_specialisee', 'officiel', 'enquete_publique')
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- PV Magazine : tres fort signal photovoltaique
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT id, 'photovoltaique', 0.95
FROM news.sources WHERE domain = 'pv-magazine.fr'
ON CONFLICT (source_id, enr_type_code) DO UPDATE SET affinity_score = EXCLUDED.affinity_score;

-- Developpeurs : fort signal sur les 3 types
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT s.id, t.code, 0.85
FROM news.sources s CROSS JOIN (VALUES ('photovoltaique'),('agrivoltaique'),('eolien')) AS t(code)
WHERE s.source_type = 'developer'
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

-- Prefectures : fort signal reglementaire sur tous types
INSERT INTO news.source_enr_affinity (source_id, enr_type_code, affinity_score)
SELECT s.id, t.code, 0.90
FROM news.sources s CROSS JOIN (VALUES ('photovoltaique'),('agrivoltaique'),('eolien')) AS t(code)
WHERE s.source_type = 'prefecture'
ON CONFLICT (source_id, enr_type_code) DO NOTHING;

DO $$ BEGIN RAISE NOTICE 'Schema news initialise avec succes'; END $$;

'@
    Write-FileUTF8NoBOM -Path "$($script:CONFIG.InstallPath)\config\init.sql" -Content $sqlContent
}

# ==============================================================================
#  Execution du SQL dans le PostgreSQL MRAE partage
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
    $psqlOutput | ForEach-Object { "$_" } | Out-Host

    if ($psqlExit -ne 0) {
        Write-Fail "Execution SQL terminee en erreur (code $psqlExit)"
        return $false
    }

    docker exec $script:CONFIG.MRAEPostgres rm -f /tmp/news_init.sql 2>&1 | Out-Null

    Write-OK "Schema news initialise"
    return $true
}