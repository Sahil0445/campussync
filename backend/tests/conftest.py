import os
import sys
import tempfile
from pathlib import Path

_tmp = tempfile.mkdtemp()
os.environ["CAMPUSSYNC_DB"] = os.environ.get("TEST_DATABASE_URL") or f"sqlite:///{Path(_tmp, 'test.db').as_posix()}"
os.environ.pop("DATABASE_URL", None)
os.environ["GEMINI_API_KEY"] = ""
os.environ["CAMPUSSYNC_AUTOPILOT_SECONDS"] = "0"
os.environ["GOOGLE_CLIENT_ID"] = ""
os.environ["CAMPUSSYNC_FRONTEND"] = str(Path(_tmp, "no-frontend"))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402
from app.seed import init_db  # noqa: E402


@pytest.fixture()
def client():
    init_db(reset=True)
    with TestClient(app) as c:
        yield c


class Api:
    def __init__(self, client, email, role):
        r = client.post("/user/login", json={"email": email, "password": "demo1234", "role": role})
        assert r.status_code == 200, r.text
        self.client = client
        self.headers = {"Authorization": f"Bearer {r.json()['token']}"}
        self.raw = []

    def __call__(self, _walker, expect=200, **body):
        r = self.client.post(f"/walker/{_walker}", json=body, headers=self.headers)
        self.raw.append(r.text)
        assert r.status_code == expect, f"{_walker}: {r.status_code} {r.text}"
        data = r.json()
        return data["reports"][0] if "reports" in data else data


@pytest.fixture()
def login(client):
    return lambda email, role="student": Api(client, email, role)


@pytest.fixture(autouse=True)
def _reset_clock():
    from app import clock

    clock.reset()
    yield
    clock.reset()


def register(client, walker_name, **body):
    r = client.post(f"/walker/{walker_name}", json=body)
    return r


class TokenApi(Api):
    def __init__(self, client, token):  # noqa: D401 - reuse Api's call
        self.client = client
        self.headers = {"Authorization": f"Bearer {token}"}
        self.raw = []


@pytest.fixture()
def signup(client):
    """signup('register_employee', name=..., ...) -> (Api, payload) or raises with the error text."""
    def go(walker_name, expect=200, **body):
        r = client.post(f"/walker/{walker_name}", json=body)
        assert r.status_code == expect, f"{walker_name}: {r.status_code} {r.text}"
        if expect != 200:
            return None, r.json()
        data = r.json()["reports"][0]
        return TokenApi(client, data["token"]), data
    return go
