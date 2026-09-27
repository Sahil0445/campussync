"""Talks to the CampusSync Jac server.

  POST /user/register, /user/login      -> Jac's built-in accounts (email + password)
  POST /function/<name>                 -> {ok, data: {result}, error: {code, message}}

`api(name, body)` keeps the old walker(name, body) call shape so every screen reads the same as before.
"""

import from react { useCallback, useEffect, useRef, useState }

glob:pub JS: any = globalThis;
glob:pub KEY: str = "campussync.session";
glob:pub ERR_DEFAULT: str = "Something went wrong. Your data is safe.";

def _safe_get(store: any) -> any {
    try {
        v: any = store.getItem(KEY);
        return v;
    } except Exception {
        return None;
    }
}

"""The signed-in session {token, role, name}: per tab first, so two roles can sit side by side on one laptop."""
def:pub getSession() -> any {
    raw: any = _safe_get(JS.window.sessionStorage);
    if not raw {
        raw = _safe_get(JS.window.localStorage);
    }
    if not raw {
        return None;
    }
    try {
        return JS.JSON.parse(raw);
    } except Exception {
        return None;
    }
}

def:pub setSession(s: any) -> None {
    for store in [JS.window.sessionStorage, JS.window.localStorage] {
        try {
            st: any = store;
            if s {
                st.setItem(KEY, JS.JSON.stringify(s));
            } else {
                st.removeItem(KEY);
            }
        } except Exception {
            continue;
        }
    }
}

"""An Error carrying the message the server gave (and the HTTP status)."""
def:pub apiError(message: str, status: int) -> Exception {
    err: any = new(JS.Error, message);
    err.status = status;
    return err;
}

"""The message to show for anything caught in a try/except."""
def:pub errMsg(e: any) -> str {
    if e and e.message {
        return e.message;
    }
    return ERR_DEFAULT;
}

def _signed_out_redirect() -> None {
    p: str = JS.location.pathname;
    if not p.startswith("/signup") and p != "/" and p != "/signin" {
        JS.location.href = "/signin";
    }
}

async def _post(path: str, body: any, auth: bool, token: str = "") -> any {
    headers: dict[str, str] = {"Content-Type": "application/json"};
    s: any = getSession();
    tok = token;
    if not tok and auth and s {
        tok = s.token;
    }
    if tok {
        headers["Authorization"] = "Bearer " + tok;
    }
    res: any = None;
    try {
        res = await JS.fetch(path, {"method": "POST", "headers": headers, "body": JS.JSON.stringify(body or {})});
    } except Exception {
        raise apiError("Can't reach CampusSync. Check your connection.", 0);
    }
    data: any = None;
    try {
        data = await res.json();
    } except Exception {
        data = None;
    }
    if not res.ok or (data and data.ok == False) {
        if res.status == 401 and auth and not token {
            setSession(None);
            _signed_out_redirect();
        }
        msg: str = ERR_DEFAULT;
        if data and data.error and data.error.message {
            msg = data.error.message;
        }
        if res.status == 401 and auth {
            msg = "Please sign in again.";
        }
        raise apiError(msg, res.status);
    }
    return data;
}

"""Call a server function by name. Returns its result."""
async def:pub api(name: str, body: any = None, auth: bool = True) -> any {
    data: any = await _post("/function/" + name, body or {}, auth);
    if data and data.data {
        return data.data.result;
    }
    return data;
}

"""Call a server function with an explicit token (used while an account is being created)."""
async def _call_as(token: str, name: str, body: any) -> any {
    data: any = await _post("/function/" + name, body or {}, True, token);
    return data.data.result;
}

async def _jac_login(email: str, password: str) -> str {
    data: any = None;
    try {
        data = await _post(
            "/user/login",
            {"identity": {"type": "email", "value": email}, "credential": {"type": "password", "password": password}},
            False
        );
    } except Exception as e {
        err: any = e;
        if err.status == 429 {
            raise apiError("Too many wrong passwords. Wait 15 minutes and try again.", 429);
        }
        if err.status == 0 {
            raise e;
        }
        raise apiError("That email and password don't match.", 401);
    }
    return data.data.token;
}

"""Sign in and check the account type matches the tab the person picked."""
async def:pub login(email: str, password: str, role: str) -> any {
    em = email.strip().lower();
    token: str = await _jac_login(em, password);
    who: any = None;
    try {
        who = await _call_as(token, "whoami", {});
    } except Exception {
        raise apiError("That email and password don't match.", 401);
    }
    if role and who.role != role {
        other = "Employer" if who.role == "department" else "Employee";
        raise apiError("This is an " + other.lower() + " account. Switch to “" + other + "” above.", 401);
    }
    s: any = {"token": token, "role": who.role, "name": who.name};
    setSession(s);
    return s;
}

"""Create an account: validate first, then the login, then the employer/employee profile.
`fn` is register_employer or register_employee; `role` is department or student."""
async def:pub signup(fn: str, role: str, body: any) -> any {
    em: str = str(body.email or "").strip().lower();
    pw: str = str(body.password or "");
    await api("check_signup", JS.Object.assign({}, body, {"role": role, "email": em}), False);
    token: str = "";
    reg: any = None;
    try {
        reg = await _post(
            "/user/register",
            {"identities": [{"type": "email", "value": em}], "credential": {"type": "password", "password": pw}, "profile": {}},
            False
        );
        token = reg.data.token or "";
    } except Exception as e {
        err: any = e;
        if err.status == 0 {
            raise e;
        }
        # The login may exist from an earlier attempt that stopped half way: finish it with the same password.
        try {
            token = await _jac_login(em, pw);
        } except Exception {
            raise apiError("An account with that email already exists. Sign in instead.", 400);
        }
    }
    if not token {
        token = await _jac_login(em, pw);
    }
    payload: any = JS.Object.assign({}, body, {"email": em});
    payload.password = JS.undefined;
    r: any = await _call_as(token, fn, payload);
    setSession({"token": token, "role": r.role, "name": r.name});
    r.token = token;
    return r;
}

"""Load a server function's result, optionally polling (live updates without a reload)."""
def:pub useWalker(name: str, body: any = None, poll: int = 0) -> dict[str, any] {
    st_data: any = useState(None);
    st_err: any = useState(None);
    st_load: any = useState(True);
    data: any = st_data[0];
    setData: any = st_data[1];
    error: any = st_err[0];
    setError: any = st_err[1];
    loading: any = st_load[0];
    setLoading: any = st_load[1];
    key: str = JS.JSON.stringify(body or {});
    alive: any = useRef(True);

    load: any = useCallback(
        lambda (quiet: any) -> any {
            async def run -> None {
                if not name {
                    return;
                }
                q: bool = quiet == True;
                if not q {
                    setLoading(True);
                }
                try {
                    d: any = await api(name, JS.JSON.parse(key));
                    if alive.current {
                        setData(d);
                        setError(None);
                    }
                } except Exception as e {
                    if alive.current and not q {
                        setError(errMsg(e));
                    }
                }
                if alive.current and not q {
                    setLoading(False);
                }
            }
            return run();
        },
        [name, key]
    );

    useEffect(
        lambda -> any {
            alive.current = True;
            load(False);
            return lambda { alive.current = False; };
        },
        [load]
    );

    useEffect(
        lambda -> any {
            if not poll {
                return JS.undefined;
            }
            iv: any = JS.window.setInterval(
                lambda {
                    if not JS.document.hidden {
                        load(True);
                    }
                },
                poll
            );
            return lambda { JS.window.clearInterval(iv); };
        },
        [load, poll]
    );

    return {"data": data, "error": error, "loading": loading, "reload": load, "setData": setData};
}
