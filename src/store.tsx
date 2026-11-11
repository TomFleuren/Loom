import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { asList, engine, getAppInfo, type AppInfo, type EngineResult, type LogLine } from "./api";

export type Page = "install" | "tweaks" | "config" | "updates" | "apps" | "windows";

interface ConfirmOptions {
  title: string;
  body: string;
  confirm: string;
  danger?: boolean;
}

interface LoomStore {
  page: Page;
  setPage: (page: Page) => void;
  info: AppInfo | null;
  busy: boolean;
  log: LogLine[];
  progress: number;
  status: string;
  logOpen: boolean;
  setLogOpen: (open: boolean) => void;
  manager: "winget" | "choco";
  setManager: (manager: "winget" | "choco") => void;
  dns: string;
  setDns: (dns: string) => void;
  apps: Set<string>;
  tweaks: Set<string>;
  features: Set<string>;
  appx: Set<string>;
  toggleSet: (kind: "apps" | "tweaks" | "features" | "appx", id: string) => void;
  replaceSet: (kind: "apps" | "tweaks" | "features" | "appx", ids: string[]) => void;
  run: (action: string, payload?: unknown) => Promise<EngineResult | null>;
  ask: (options: ConfirmOptions) => Promise<boolean>;
  dialog: (ConfirmOptions & { open: boolean }) | null;
  answer: (yes: boolean) => void;
}

const LoomContext = createContext<LoomStore | null>(null);

function loadSet(key: string) {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || "[]") as string[];
    return new Set(parsed);
  } catch {
    return new Set<string>();
  }
}

function saveSet(key: string, value: Set<string>) {
  localStorage.setItem(key, JSON.stringify([...value]));
}

export function LoomProvider({ children }: { children: ReactNode }) {
  const [page, setPage] = useState<Page>("install");
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const [log, setLog] = useState<LogLine[]>([]);
  const [progress, setProgress] = useState(-1);
  const [status, setStatus] = useState("Ready");
  const [logOpen, setLogOpen] = useState(false);
  const [manager, setManager] = useState<"winget" | "choco">("winget");
  const [dns, setDns] = useState("Default");
  const [apps, setApps] = useState(() => loadSet("loom-apps"));
  const [tweaks, setTweaks] = useState(() => loadSet("loom-tweaks"));
  const [features, setFeatures] = useState(() => loadSet("loom-features"));
  const [appx, setAppx] = useState(() => loadSet("loom-appx"));
  const [dialog, setDialog] = useState<(ConfirmOptions & { open: boolean }) | null>(null);
  const answerRef = useRef<(value: boolean) => void>(() => {});

  useEffect(() => {
    void getAppInfo().then(setInfo).catch(() => setInfo(null));
  }, []);

  useEffect(() => saveSet("loom-apps", apps), [apps]);
  useEffect(() => saveSet("loom-tweaks", tweaks), [tweaks]);
  useEffect(() => saveSet("loom-features", features), [features]);
  useEffect(() => saveSet("loom-appx", appx), [appx]);

  const sets = { apps: setApps, tweaks: setTweaks, features: setFeatures, appx: setAppx };

  const value = useMemo<LoomStore>(() => {
    function toggleSet(kind: keyof typeof sets, id: string) {
      sets[kind]((current) => {
        const next = new Set(current);
        if (next.has(id)) next.delete(id);
        else next.add(id);
        return next;
      });
    }
    function replaceSet(kind: keyof typeof sets, ids: string[]) {
      sets[kind](new Set(ids));
    }
    async function run(action: string, payload: unknown = {}) {
      if (busy) return null;
      setBusy(true);
      setLogOpen(true);
      setProgress(0);
      setStatus("Working");
      try {
        const result = await engine<EngineResult>(action, payload, (line) => {
          setLog((current) => [...current.slice(-240), line]);
          if (line.percent >= 0) setProgress(line.percent);
          setStatus(line.message);
        });
        if (result?.ok === false) setStatus(result.error || "That change did not finish.");
        else if (result) setStatus("Finished");
        return result;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        setStatus(message);
        setLog((current) => [...current, { level: "ERROR", message, percent: -1 }]);
        return null;
      } finally {
        setBusy(false);
      }
    }
    function ask(options: ConfirmOptions) {
      return new Promise<boolean>((resolve) => {
        answerRef.current = resolve;
        setDialog({ ...options, open: true });
      });
    }
    function answer(yes: boolean) {
      setDialog(null);
      answerRef.current(yes);
    }
    return {
      page, setPage, info, busy, log, progress, status, logOpen, setLogOpen,
      manager, setManager, dns, setDns, apps, tweaks, features, appx,
      toggleSet, replaceSet, run, ask, dialog, answer,
    };
  }, [page, info, busy, log, progress, status, logOpen, manager, dns, apps, tweaks, features, appx]);

  return <LoomContext.Provider value={value}>{children}</LoomContext.Provider>;
}

export function useLoom() {
  const value = useContext(LoomContext);
  if (!value) throw new Error("Loom store is missing");
  return value;
}

export { asList };
