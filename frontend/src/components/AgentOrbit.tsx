import { useEffect, useState } from "react";
import { CalendarRange, CalendarClock, MessageSquareText, Network, Repeat, Scale, ShieldCheck, UserPlus } from "lucide-react";

export const AGENT_META: { name: string; short: string; kind: "agent" | "rules"; Icon: typeof Network }[] = [
  { name: "Availability Agent", short: "Availability", kind: "agent", Icon: CalendarClock },
  { name: "Conflict Agent", short: "Conflict", kind: "rules", Icon: ShieldCheck },
  { name: "Compliance Checker", short: "Compliance", kind: "rules", Icon: Scale },
  { name: "Scheduling Agent", short: "Scheduling", kind: "agent", Icon: CalendarRange },
  { name: "Swap Agent", short: "Swap", kind: "agent", Icon: Repeat },
  { name: "Recruiting Agent", short: "Recruiting", kind: "agent", Icon: UserPlus },
  { name: "Explainer", short: "Explainer", kind: "agent", Icon: MessageSquareText },
  { name: "Coordinator", short: "Coordinator", kind: "agent", Icon: Network },
];

/** The agent network. Nodes light up (and their links carry traffic) when an agent is working. */
export function AgentOrbit({ active = [], cycle = false, compact = false }: { active?: string[]; cycle?: boolean; compact?: boolean }) {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!cycle) return;
    const id = window.setInterval(() => setTick((t) => t + 1), 900);
    return () => window.clearInterval(id);
  }, [cycle]);
  const cycled = cycle ? [AGENT_META[tick % 7].name, AGENT_META[(tick + 3) % 7].name, "Coordinator"] : [];
  const on = new Set([...active, ...cycled]);
  const W = 520, c = W / 2, R = compact ? 178 : 190;
  const ring = AGENT_META.slice(0, 7);
  return (
    <svg className="orbit" viewBox={`0 0 ${W} ${W}`} role="img" aria-label="CampusSync agent network">
      <defs>
        <linearGradient id="og" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#a18bff" /><stop offset="0.5" stopColor="#6c8cff" /><stop offset="1" stopColor="#3dd8f5" /></linearGradient>
        <radialGradient id="cg" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stopColor="#c7bcff" /><stop offset="0.45" stopColor="#6c8cff" /><stop offset="1" stopColor="#1f7a94" /></radialGradient>
        <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4" result="b" /><feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge></filter>
      </defs>
      <circle className="ring" cx={c} cy={c} r={R + 46} />
      <circle className="ring dash" cx={c} cy={c} r={R} />
      <circle className="ring" cx={c} cy={c} r={92} />
      {ring.map((a, i) => {
        const ang = -Math.PI / 2 + (2 * Math.PI * i) / ring.length;
        const x = c + R * Math.cos(ang), y = c + R * Math.sin(ang);
        return <line key={`e${a.name}`} className={`edge ${on.has(a.name) ? "on" : ""}`} x1={c} y1={c} x2={x} y2={y} />;
      })}
      <g>
        <circle cx={c} cy={c} r={64} fill="rgba(108,140,255,0.08)" />
        <circle className="core" cx={c} cy={c} r={46} />
        <text x={c} y={c - 4} textAnchor="middle" fontSize="13" fontWeight="600" fill="#070812">Coordinator</text>
        <text x={c} y={c + 13} textAnchor="middle" fontSize="10" fill="#0b1030" fontFamily="var(--mono)">{on.size ? `${on.size - (on.has("Coordinator") ? 1 : 0)} active` : "idle"}</text>
      </g>
      {ring.map((a, i) => {
        const ang = -Math.PI / 2 + (2 * Math.PI * i) / ring.length;
        const x = c + R * Math.cos(ang), y = c + R * Math.sin(ang);
        const lit = on.has(a.name);
        const below = Math.sin(ang) > 0.2;
        return (
          <g key={a.name} className={`node ${lit ? "on" : ""}`}>
            <circle className="halo" cx={x} cy={y} r={40} />
            <circle className="bg" cx={x} cy={y} r={27} />
            <a.Icon x={x - 11} y={y - 11} width={22} height={22} color={lit ? "#dfe3ff" : "#8a90a6"} strokeWidth={1.6} />
            <text x={x} y={below ? y + 46 : y - 38} textAnchor="middle">{a.short}</text>
            <text x={x} y={below ? y + 60 : y - 52} textAnchor="middle" style={{ fontSize: 9, fill: a.kind === "rules" ? "#7fdcf0" : "#a9b2ff", opacity: 0.8 }}>
              {a.kind === "rules" ? "RULES · CODE" : "AGENT · AI"}
            </text>
          </g>
        );
      })}
    </svg>
  );
}
