from __future__ import annotations

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import DB_URL

_connect_args = {"check_same_thread": False, "timeout": 30} if DB_URL.startswith("sqlite") else {}
_pool = {} if DB_URL.startswith("sqlite") else {"pool_pre_ping": True, "pool_size": 5, "max_overflow": 5, "pool_recycle": 280}
engine = create_engine(DB_URL, connect_args=_connect_args, future=True, **_pool)

if DB_URL.startswith("sqlite"):

    @event.listens_for(engine, "connect")
    def _sqlite_pragmas(dbapi_conn, _record):  # pragma: no cover - driver hook
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.execute("PRAGMA journal_mode=WAL")
        cur.close()


SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
