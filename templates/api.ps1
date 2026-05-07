# ==============================================================================
#  templates/api.ps1
#  Tout le contenu du service api/ : Dockerfile, requirements.txt, main.py
# ==============================================================================

function Get-DockerfileApiContent {
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

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
'@
}

function Get-ApiRequirementsContent {
    return @'
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
psycopg2-binary==2.9.9
redis==5.0.8
python-dotenv==1.0.1
loguru==0.7.2
'@
}

function Get-ApiMainPyContent {
    return @'
# -*- coding: utf-8 -*-
"""
NEWS Scraper -- API FastAPI

Points d'entree :
  GET  /                      Info service
  GET  /health                Health check (DB + Redis)
  POST /search                Cree un job de recherche
  GET  /search/{job_id}       Recupere le statut et le resultat d'un job
  GET  /jobs/recent?limit=N   Liste les N derniers jobs (debug)
"""
import os
import json
import uuid
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

import redis
import psycopg2
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field, field_validator
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

# Conventions de nommage des cles Redis
JOB_KEY_PREFIX = "news:job:"
QUEUE_KEY      = "news:queue"
RECENT_KEY     = "news:recent"        # liste des job_id recents (pour /jobs/recent)
JOB_TTL_DAYS   = 7
RECENT_MAX     = 100                   # on garde les 100 derniers job_id

# Aligne sur la taxonomie MRAE.type_projet.
# Les 5 premiers sont les types d'interet principal du projet :
#   agrivoltaique, photovoltaique, eolien, poste (electrique source), stockage.
# Les 5 suivants sont supportes pour completude mais hors du perimetre core.
VALID_ENR_TYPES = {
    "agrivoltaique", "photovoltaique", "eolien", "poste", "stockage",
    "biomasse", "fossile", "geothermie", "hydraulique", "nucleaire",
}

# ==============================================================================
#  Modeles Pydantic
# ==============================================================================

class JobStatus(str, Enum):
    queued     = "queued"
    processing = "processing"
    done       = "done"
    error      = "error"

class SearchRequest(BaseModel):
    commune:    str = Field(..., min_length=1, max_length=100, description="Nom de la commune")
    dept_code:  str = Field(..., pattern=r"^\d{2,3}[AB]?$",    description="Code departement (ex: '003', '2A')")
    enr_type:   str = Field(..., description="Type ENR a rechercher (un seul par job)")
    radius_km:  int = Field(default=30, ge=1, le=200,          description="Rayon de recherche en km")

    @field_validator("enr_type")
    @classmethod
    def check_enr_type(cls, v):
        if v not in VALID_ENR_TYPES:
            raise ValueError(
                "Type ENR invalide : '{}'. Valeurs acceptees : {}".format(
                    v, sorted(VALID_ENR_TYPES)
                )
            )
        return v

    @field_validator("dept_code")
    @classmethod
    def normalize_dept_code(cls, v):
        # Normalisation : '3' -> '003', '34' -> '034', '034' -> '034', '2A' -> '02A'
        v = v.strip().upper()
        if v in ("2A", "2B"):
            return "0" + v
        if v.isdigit():
            return v.zfill(3)
        return v

class SearchResponse(BaseModel):
    job_id:     str
    status:     JobStatus
    created_at: datetime
    message:    str = "Job cree. Utilisez GET /search/{job_id} pour suivre son avancement."

class JobDetail(BaseModel):
    job_id:       str
    status:       JobStatus
    commune:      str
    dept_code:    str
    enr_type:     str
    radius_km:    int
    created_at:   datetime
    updated_at:   datetime
    started_at:   Optional[datetime] = None
    finished_at:  Optional[datetime] = None
    result:       Optional[dict]     = None
    error:        Optional[str]      = None
    progress:     Optional[dict]     = None  # compteurs pendant l'execution

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
#  Helpers
# ==============================================================================

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def _job_key(job_id: str) -> str:
    return "{}{}".format(JOB_KEY_PREFIX, job_id)

def _save_job(r, job: dict) -> None:
    """Persiste un job dans Redis avec TTL et ajout dans la liste des jobs recents."""
    key = _job_key(job["job_id"])
    r.set(key, json.dumps(job, default=str), ex=JOB_TTL_DAYS * 86400)
    # Liste ordonnee des job_id recents (le plus recent en tete)
    r.lpush(RECENT_KEY, job["job_id"])
    r.ltrim(RECENT_KEY, 0, RECENT_MAX - 1)

def _load_job(r, job_id: str) -> Optional[dict]:
    raw = r.get(_job_key(job_id))
    if raw is None:
        return None
    return json.loads(raw)

# ==============================================================================
#  Application
# ==============================================================================

app = FastAPI(
    title="NEWS Scraper API",
    version="0.1.0",
    description="Agent de veille ENR -- point d'entree pour les recherches geolocalisees."
)

@app.get("/")
def root():
    return {
        "service": "news_api",
        "version": "0.1.0",
        "status":  "ok",
        "endpoints": ["/health", "/search", "/search/{job_id}", "/jobs/recent"],
    }

@app.get("/health")
def health():
    """Verifie la disponibilite des dependances : Redis et PostgreSQL."""
    checks = {"redis": False, "postgres": False, "schema_enr_agent": False}

    # Redis
    try:
        r = get_redis()
        r.ping()
        checks["redis"] = True
    except Exception as e:
        logger.warning("Redis indisponible : {}".format(e))

    # PostgreSQL + schema enr_agent
    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'enr_agent'"
            )
            checks["postgres"] = True
            checks["schema_enr_agent"] = cur.fetchone() is not None
        conn.close()
    except Exception as e:
        logger.warning("PostgreSQL indisponible : {}".format(e))

    all_ok = all(checks.values())
    return {"ok": all_ok, "checks": checks}

@app.post("/search", response_model=SearchResponse, status_code=201)
def create_search(req: SearchRequest):
    """
    Cree un job de recherche ENR pour une commune donnee.
    Le job est immediatement mis en file (Redis queue) pour traitement par news_agent.
    """
    job_id = str(uuid.uuid4())
    now    = _now_iso()

    job = {
        "job_id":      job_id,
        "status":      JobStatus.queued.value,
        "commune":     req.commune,
        "dept_code":   req.dept_code,
        "enr_type":    req.enr_type,
        "radius_km":   req.radius_km,
        "created_at":  now,
        "updated_at":  now,
        "started_at":  None,
        "finished_at": None,
        "result":      None,
        "error":       None,
        "progress":    None,
    }

    try:
        r = get_redis()
        _save_job(r, job)
        r.lpush(QUEUE_KEY, job_id)
    except redis.RedisError as e:
        logger.error("Echec Redis lors de la creation du job : {}".format(e))
        raise HTTPException(status_code=503, detail="File de taches indisponible")

    logger.info("Job cree : {} -> {} ({}) type={}".format(
        job_id, req.commune, req.dept_code, req.enr_type
    ))

    return SearchResponse(
        job_id=job_id,
        status=JobStatus.queued,
        created_at=datetime.fromisoformat(now),
    )

@app.get("/search/{job_id}", response_model=JobDetail)
def get_search(job_id: str):
    """Recupere le statut et le resultat d'un job."""
    try:
        r   = get_redis()
        job = _load_job(r, job_id)
    except redis.RedisError as e:
        logger.error("Echec Redis lors de la lecture du job {} : {}".format(job_id, e))
        raise HTTPException(status_code=503, detail="File de taches indisponible")

    if job is None:
        raise HTTPException(status_code=404, detail="Job introuvable ou expire (TTL {} jours)".format(JOB_TTL_DAYS))

    return JobDetail(**job)

@app.get("/jobs/recent")
def list_recent_jobs(limit: int = Query(default=20, ge=1, le=RECENT_MAX)):
    """Retourne les N derniers jobs (metadonnees uniquement, sans le resultat complet)."""
    try:
        r        = get_redis()
        job_ids  = r.lrange(RECENT_KEY, 0, limit - 1)
    except redis.RedisError as e:
        raise HTTPException(status_code=503, detail="File de taches indisponible")

    jobs = []
    for jid in job_ids:
        job = _load_job(r, jid)
        if job is None:
            continue
        # Resume leger (sans le resultat complet qui peut etre volumineux)
        jobs.append({
            "job_id":     job["job_id"],
            "status":     job["status"],
            "commune":    job["commune"],
            "dept_code":  job["dept_code"],
            "enr_type":   job["enr_type"],
            "created_at": job["created_at"],
            "updated_at": job["updated_at"],
        })
    return {"count": len(jobs), "jobs": jobs}
'@
}
