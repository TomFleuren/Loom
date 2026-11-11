import { useEffect, useState } from "react";
import { elevate, getAppInfo, installLoom, isTauri, saveTextFile, uninstallLoom, type AppInfo } from "./api";
import { AppsPage, ConfigPage, InstallPage, TweaksPage, UpdatesPage, WindowsPage } from "./pages";
import { LoomProvider, useLoom, type Page } from "./store";

function Mark() {
  return (
    <svg viewBox="0 0 32 32" aria-hidden="true">
      <rect x="3" y="3" width="26" height="26" rx="8" fill="#010521" />
      <path d="M9 16.2c2.2-3.4 4.6-5.2 7-5.2 2.6 0 4.2 1.6 4.2 3.7 0 4.2-6.4 3.6-6.4 6.6 0 1.2.8 2 2.2 2 1.6 0 3.2-.8 4.6-2.2" fill="none" stroke="#97e6ff" strokeWidth="2.2" strokeLinecap="round" />
    </svg>
  );
}

const pages: { id: Page; label: string }[] = [
  { id: "install", label: "Install" },
  { id: "tweaks", label: "Tweaks" },
  { id: "config", label: "Config" },
  { id: "updates", label: "Updates" },
  { id: "apps", label: "Apps" },
  { id: "windows", label: "Windows" },
];

function Titlebar() {
  async function act(kind: "min" | "max" | "close") {
    if (!isTauri()) return;
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    const current = getCurrentWindow();
    if (kind === "min") await current.minimize();
    if (kind === "max") await current.toggleMaximize();
    if (kind === "close") await current.close();
  }
  return (
    <header className="titlebar" data-tauri-drag-region>
      <div className="brand" data-tauri-drag-region>
        <Mark />
        <span>Loom</span>
      </div>
      <div className="title-gap" data-tauri-drag-region />
      <button className="win-btn" type="button" aria-label="Minimize" onClick={() => void act("min")}>–</button>
      <button className="win-btn" type="button" aria-label="Maximize" onClick={() => void act("max")}>□</button>
      <button className="win-btn close" type="button" aria-label="Close" onClick={() => void act("close")}>×</button>
    </header>
  );
}

function Shell() {
  const loom = useLoom();
  const [notice, setNotice] = useState<string | null>(null);
  const page = {
    install: <InstallPage />,
    tweaks: <TweaksPage />,
    config: <ConfigPage />,
    updates: <UpdatesPage />,
    apps: <AppsPage />,
    windows: <WindowsPage />,
  }[loom.page];
  const counts = {
    install: loom.apps.size,
    tweaks: loom.tweaks.size,
    config: loom.features.size,
    updates: 0,
    apps: loom.appx.size,
    windows: 0,
  };

  function flash(message: string) {
    setNotice(message);
    window.setTimeout(() => setNotice((current) => (current === message ? null : current)), 2400);
  }

  function exportSelection() {
    const data = {
      apps: [...loom.apps],
      tweaks: [...loom.tweaks],
      features: [...loom.features],
      appx: [...loom.appx],
      dns: loom.dns,
      manager: loom.manager,
    };
    void saveTextFile("loom-selection.json", JSON.stringify(data, null, 2))
      .then((saved) => {
        if (saved) flash("Selection saved");
      })
      .catch((error: unknown) => {
        flash(error instanceof Error ? error.message : "Could not save the selection");
      });
  }

  function importSelection(file: File) {
    void file.text().then((text) => {
      const data = JSON.parse(text) as { apps?: string[]; tweaks?: string[]; features?: string[]; appx?: string[]; dns?: string; manager?: "winget" | "choco" };
      if (data.apps) loom.replaceSet("apps", data.apps);
      if (data.tweaks) loom.replaceSet("tweaks", data.tweaks);
      if (data.features) loom.replaceSet("features", data.features);
      if (data.appx) loom.replaceSet("appx", data.appx);
      if (data.dns) loom.setDns(data.dns);
      if (data.manager) loom.setManager(data.manager);
    });
  }

  return (
    <div className="workspace">
      <aside className="sidebar">
        <nav className="side-nav" aria-label="Loom">
          {pages.map((item) => (
            <button key={item.id} className={loom.page === item.id ? "side-link active" : "side-link"} type="button" onClick={() => loom.setPage(item.id)}>
              <span>{item.label}</span>
              {counts[item.id] ? <small>{counts[item.id]}</small> : null}
            </button>
          ))}
        </nav>
        <div className="side-foot">
          <span className={loom.info?.admin ? "chip good" : "chip warn"}>{loom.info?.admin ? "Administrator" : "Limited"}</span>
          {!loom.info?.admin ? <button className="btn" type="button" onClick={() => void elevate("app")}>Restart as admin</button> : null}
          <button className="btn quiet" type="button" onClick={exportSelection}>Export selection</button>
          <label className="btn quiet">
            Import
            <input hidden type="file" accept="application/json" onChange={(event) => {
              const file = event.target.files?.[0];
              if (file) importSelection(file);
            }} />
          </label>
        </div>
      </aside>
      <main className="stage">
        <div key={loom.page} className="page">
          {page}
        </div>
        <LogDock />
      </main>
      {notice ? <div className="toast" role="status">{notice}</div> : null}
      {loom.dialog ? (
        <div className="overlay">
          <div className="dialog" role="dialog" aria-modal="true">
            <h2>{loom.dialog.title}</h2>
            <p>{loom.dialog.body}</p>
            <div className="dialog-actions">
              <button className="btn" type="button" onClick={() => loom.answer(false)}>Cancel</button>
              <button className={loom.dialog.danger ? "btn danger" : "btn primary"} type="button" onClick={() => loom.answer(true)}>{loom.dialog.confirm}</button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function LogDock() {
  const loom = useLoom();
  return (
    <div className="dock">
      <div className="dock-bar">
        <button className="btn quiet" type="button" onClick={() => loom.setLogOpen(!loom.logOpen)}>{loom.logOpen ? "Hide log" : "Show log"}</button>
        <span className="grow" />
        <span className="hint" style={{ margin: 0 }}>{loom.status}</span>
      </div>
      {loom.busy ? (
        <div className="track" aria-hidden="true"><span style={{ width: `${Math.max(loom.progress, 8)}%` }} /></div>
      ) : null}
      {loom.logOpen ? (
        <div className="log" aria-live="polite">
          {loom.log.length === 0 ? <div>Waiting for the next change.</div> : null}
          {loom.log.slice(-80).map((line, index) => (
            <div key={`${index}-${line.message}`} className={line.level === "ERROR" ? "error" : line.level === "WARN" ? "warn" : ""}>
              {line.message}
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function Setup({ info }: { info: AppInfo }) {
  const [desktop, setDesktop] = useState(true);
  const [menu, setMenu] = useState(true);
  const [phase, setPhase] = useState<"ask" | "work" | "done" | "error">("ask");
  const [message, setMessage] = useState("");
  const uninstalling = info.mode === "uninstall";

  async function install() {
    if (!info.admin) {
      await elevate(info.mode);
      return;
    }
    setPhase("work");
    try {
      const path = await installLoom(desktop, menu);
      setMessage(path);
      setPhase("done");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : String(error));
      setPhase("error");
    }
  }

  async function remove() {
    if (!info.admin) {
      await elevate("uninstall");
      return;
    }
    setPhase("work");
    try {
      await uninstallLoom();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : String(error));
      setPhase("error");
    }
  }

  async function launch() {
    if (!isTauri()) return;
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    await getCurrentWindow().close();
  }

  return (
    <div className="setup">
      <section className="setup-card">
        <div className="brand"><Mark /><span>Loom</span></div>
        <h1>{uninstalling ? "Remove" : "Install"}</h1>
        <p className="lede">
          {uninstalling
            ? "This removes Loom from this PC, including its Start menu and desktop shortcuts."
            : "A Windows utility for installs, tweaks, repairs, and a cleaner Windows setup."}
        </p>
        {phase === "ask" ? (
          <>
            <div className="path">{info.installPath}</div>
            {uninstalling ? null : (
              <>
                <label className="option"><input type="checkbox" checked={menu} onChange={(event) => setMenu(event.target.checked)} /> Start menu shortcut</label>
                <label className="option"><input type="checkbox" checked={desktop} onChange={(event) => setDesktop(event.target.checked)} /> Desktop shortcut</label>
              </>
            )}
            {!info.admin ? <p className="hint">Windows will ask for administrator approval.</p> : null}
            <div className="tools" style={{ marginTop: 18 }}>
              {uninstalling ? (
                <button className="btn danger" type="button" onClick={() => void remove()}>Remove Loom</button>
              ) : (
                <button className="btn primary" type="button" onClick={() => void install()}>{info.installed ? "Reinstall" : "Install Loom"}</button>
              )}
            </div>
          </>
        ) : null}
        {phase === "work" ? <p className="lede">Working…</p> : null}
        {phase === "done" ? (
          <>
            <p className="lede">Loom is installed.</p>
            <div className="path">{message}</div>
            <button className="btn primary" type="button" onClick={() => void launch()}>Close</button>
          </>
        ) : null}
        {phase === "error" ? <p className="lede">{message}</p> : null}
      </section>
    </div>
  );
}

function Root() {
  const [info, setInfo] = useState<AppInfo | null>(null);
  useEffect(() => {
    void getAppInfo().then(setInfo).catch(() => setInfo({
      mode: "app",
      version: "1.0.0",
      admin: false,
      installed: false,
      installPath: "C:\\Program Files\\Loom",
      exe: "",
    }));
  }, []);
  if (!info) return <div className="app" />;
  return (
    <div className="app">
      <Titlebar />
      {info.mode === "app" ? (
        <LoomProvider>
          <Shell />
        </LoomProvider>
      ) : (
        <Setup info={info} />
      )}
    </div>
  );
}

export function App() {
  return <Root />;
}
