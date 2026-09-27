// Talks to the backend exactly the way a `jac serve` app is called:
//   POST /user/login          -> { token, role, name }
//   POST /walker/<name>       -> { reports: [result] }
// Porting to JacHammer means pointing API_BASE at the Jac server; nothing else changes.
import { useCallback, useEffect, useRef, useState } from "react";

export const API_BASE: string = (import.meta as any).env?.VITE_API_BASE ?? "";

export type Role = "student" | "department";
export interface Session { token: string; role: Role; name: string }

const KEY = "campussync.session";

function safeGet(store: Storage | undefined): string | null {
  try { return store?.getItem(KEY) ?? null; } catch { return null; }
}

export function getSession(): Session | null {
  // Per-tab session first, so two roles can be signed in side by side on one laptop.
  const raw = safeGet(window.sessionStorage) ?? safeGet(window.localStorage);
  if (!raw) return null;
  try { return JSON.parse(raw) as Session; } catch { return null; }
}

export function setSession(s: Session | null) {
  for (const store of [window.sessionStorage, window.localStorage]) {
    try { s ? store.setItem(KEY, JSON.stringify(s)) : store.removeItem(KEY); } catch { /* storage unavailable */ }
  }
}

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
}

async function post(path: string, body: unknown, auth = true) {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  const s = getSession();
  if (auth && s) headers.Authorization = `Bearer ${s.token}`;
  let res: Response;
  try {
    res = await fetch(`${API_BASE}${path}`, { method: "POST", headers, body: JSON.stringify(body ?? {}) });
  } catch {
    throw new ApiError("Can't reach CampusSync. Check your connection.", 0);
  }
  let data: any = null;
  try { data = await res.json(); } catch { /* empty */ }
  if (!res.ok) {
    if (res.status === 401 && auth) {
      setSession(null);
      if (!location.pathname.startsWith("/signup") && location.pathname !== "/" && location.pathname !== "/signin") location.href = "/signin";
    }
    throw new ApiError(data?.error ?? "Something went wrong. Your data is safe.", res.status);
  }
  return data;
}

export async function walker<T = any>(name: string, body: Record<string, unknown> = {}, auth = true): Promise<T> {
  const data = await post(`/walker/${name}`, body, auth);
  return (data?.reports?.[0] ?? data) as T;
}

export async function login(email: string, password: string, role: Role): Promise<Session> {
  const s = (await post("/user/login", { email, password, role }, false)) as Session;
  setSession(s);
  return s;
}

/** Load a walker's result, optionally polling (for live updates without a reload). */
export function useWalker<T = any>(name: string | null, body: Record<string, unknown> = {}, opts: { poll?: number } = {}) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const key = JSON.stringify(body);
  const alive = useRef(true);

  const load = useCallback(async (quiet = false) => {
    if (!name) return;
    if (!quiet) setLoading(true);
    try {
      const d = await walker<T>(name, JSON.parse(key));
      if (alive.current) { setData(d); setError(null); }
    } catch (e: any) {
      if (alive.current && !quiet) setError(e.message);
    } finally {
      if (alive.current && !quiet) setLoading(false);
    }
  }, [name, key]);

  useEffect(() => {
    alive.current = true;
    load();
    return () => { alive.current = false; };
  }, [load]);

  useEffect(() => {
    if (!opts.poll) return;
    const id = window.setInterval(() => { if (!document.hidden) load(true); }, opts.poll);
    return () => window.clearInterval(id);
  }, [load, opts.poll]);

  return { data, error, loading, reload: load, setData };
}
