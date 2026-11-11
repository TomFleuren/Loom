import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { engine, pickIso, saveIso, type EngineResult } from "./api";
import {
  appCategories,
  appx,
  apps,
  buttonTweaks,
  categoryName,
  checkboxTweaks,
  comboTweaks,
  entries,
  featureButtons,
  grouped,
  matches,
  presets,
  selectableFeatures,
  toggleTweaks,
  tweakCategories,
  type FeatureItem,
} from "./catalog";
import { asList, useLoom } from "./store";

function Check({ on }: { on: boolean }) {
  return <input className="check" type="checkbox" readOnly checked={on} tabIndex={-1} />;
}

function InfoButton({ label, title, body, kicker, footnote }: { label: string; title: string; body?: string; kicker?: string; footnote?: string }) {
  const [open, setOpen] = useState(false);
  const [place, setPlace] = useState({ top: 0, left: 0 });
  const buttonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", onKey);
    window.addEventListener("scroll", close, true);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("scroll", close, true);
    };
  }, [open]);

  return (
    <>
      <button
        ref={buttonRef}
        className="linkish"
        type="button"
        onPointerDown={(event) => event.stopPropagation()}
        onClick={(event) => {
          event.stopPropagation();
          const rect = buttonRef.current?.getBoundingClientRect();
          if (!rect) return;
          const width = 300;
          setPlace({
            top: Math.min(rect.bottom + 8, window.innerHeight - 180),
            left: Math.max(12, Math.min(rect.left, window.innerWidth - width - 12)),
          });
          setOpen((current) => !current);
        }}
      >
        {label}
      </button>
      {open
        ? createPortal(
            <div className="popover" style={{ top: place.top, left: place.left }} onPointerDown={(event) => event.stopPropagation()}>
              {kicker ? <p className="kicker">{kicker}</p> : null}
              <strong>{title}</strong>
              <p>{body || "Nothing else is noted for this item."}</p>
              {footnote ? <p className="footnote">{footnote}</p> : null}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}

export function InstallPage() {
  const loom = useLoom();
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("All");
  const categories = ["All", ...appCategories];
  const visible = entries(apps).filter(([, item]) => {
    if (category !== "All" && item.category !== category) return false;
    return matches(query, item.content, item.description, item.winget, item.choco);
  });

  async function selectedInstalled() {
    const result = await loom.run("installed", { manager: loom.manager });
    if (result?.ok) loom.replaceSet("apps", asList(result.ids));
  }

  return (
    <>
      <header className="page-head">
        <div>
          <h1>Install</h1>
          <p className="lede">Pick the programs you want. Loom installs them with WinGet, or Chocolatey when you choose it.</p>
        </div>
        <div className="tools">
          <input className="search" value={query} placeholder="Search apps" onChange={(event) => setQuery(event.target.value)} />
          <select className="select" value={loom.manager} onChange={(event) => loom.setManager(event.target.value as "winget" | "choco")}>
            <option value="winget">WinGet</option>
            <option value="choco">Chocolatey</option>
          </select>
        </div>
      </header>
      <div className="filters">
        {categories.map((name) => (
          <button key={name} className={category === name ? "filter on" : "filter"} type="button" onClick={() => setCategory(name)}>
            {name}
          </button>
        ))}
      </div>
      <div className="scroll">
        <div className="grid">
          {visible.map(([id, item]) => (
            <div key={id} className={loom.apps.has(id) ? "card on" : "card"} onClick={() => loom.toggleSet("apps", id)} role="button" tabIndex={0} onKeyDown={(event) => { if (event.key === "Enter") loom.toggleSet("apps", id); }}>
              <img className="icon" alt="" src={`/icons/${id}.png`} onError={(event) => { event.currentTarget.style.visibility = "hidden"; }} />
              <span>
                <span className="title-row">
                  <b>{item.content}</b>
                  {item.foss ? <span className="chip good">Open source</span> : null}
                  <i className={loom.apps.has(id) ? "dot on" : "dot"} />
                </span>
                <p>{item.description}</p>
                <InfoButton
                  label="Details"
                  title={item.content}
                  kicker={item.category}
                  body={[item.description, item.winget ? `WinGet: ${item.winget}` : "", item.choco ? `Chocolatey: ${item.choco}` : ""].filter(Boolean).join("\n")}
                  footnote={item.link.includes("winutil.christitus.com") ? undefined : item.link}
                />
              </span>
            </div>
          ))}
        </div>
      </div>
      <div className="dock">
        <div className="dock-bar">
          <strong>{loom.apps.size} selected</strong>
          <button className="btn quiet" type="button" onClick={() => loom.replaceSet("apps", [])}>Clear</button>
          <button className="btn quiet" type="button" disabled={loom.busy} onClick={() => void selectedInstalled()}>Select installed</button>
          <span className="grow" />
          <button className="btn" type="button" disabled={loom.busy} onClick={() => void loom.run("packages", { mode: "upgrade-all", manager: loom.manager })}>Upgrade all</button>
          <button className="btn" type="button" disabled={loom.busy || loom.apps.size === 0} onClick={() => void loom.run("packages", { mode: "uninstall", manager: loom.manager, ids: [...loom.apps] })}>Uninstall</button>
          <button className="btn primary" type="button" disabled={loom.busy || loom.apps.size === 0} onClick={() => void loom.run("packages", { mode: "install", manager: loom.manager, ids: [...loom.apps] })}>Install</button>
        </div>
      </div>
    </>
  );
}

export function TweaksPage() {
  const loom = useLoom();
  const [query, setQuery] = useState("");
  const [live, setLive] = useState<Record<string, boolean>>({});
  const [combos, setCombos] = useState<Record<string, string>>({});

  useEffect(() => {
    let cancel = false;
    void engine<EngineResult>("states", {}, () => {}).then((result) => {
      if (cancel || !result?.ok) return;
      setLive(result.toggles ?? {});
      const next: Record<string, string> = {};
      for (const [key, value] of Object.entries(result.combos ?? {})) {
        if (value) next[key] = value;
      }
      setCombos(next);
    }).catch(() => {});
    return () => { cancel = true; };
  }, []);

  const groups = useMemo(() => grouped(
    checkboxTweaks.filter(([, item]) => matches(query, item.Content, item.Description)),
    (item) => item.category,
    tweakCategories,
  ), [query]);

  function applyPreset(name: string) {
    loom.replaceSet("tweaks", presets[name] ?? []);
  }

  async function flip(key: string, next: boolean) {
    setLive((current) => ({ ...current, [key]: next }));
    const result = await loom.run("apply-tweaks", { keys: [key], undo: !next, dns: "Default" });
    if (!result?.ok) setLive((current) => ({ ...current, [key]: !next }));
  }

  async function chooseCombo(key: string, state: string) {
    setCombos((current) => ({ ...current, [key]: state }));
    if (key === "WPFchangedns") {
      loom.setDns(state);
      return;
    }
    const result = await loom.run("combo", { key, state });
    if (!result?.ok) setCombos((current) => ({ ...current, [key]: current[key] }));
  }

  return (
    <>
      <header className="page-head">
        <div>
          <h1>Tweaks</h1>
          <p className="lede">The same essential, preference, and advanced changes. Undo puts registry and service values back when the original state is known.</p>
        </div>
        <input className="search" value={query} placeholder="Search tweaks" onChange={(event) => setQuery(event.target.value)} />
      </header>
      <div className="scroll">
        {!loom.info?.admin ? <AdminNote /> : null}
        <div className="tools band">
          <button className="btn" type="button" onClick={() => applyPreset("Minimal")}>Minimal</button>
          <button className="btn" type="button" onClick={() => applyPreset("Standard")}>Standard</button>
          <button className="btn" type="button" onClick={() => applyPreset("Advanced")}>Advanced</button>
          <button className="btn quiet" type="button" onClick={() => loom.replaceSet("tweaks", [])}>Clear</button>
        </div>
        {groups.map((group) => (
          <section className="section" key={group.name}>
            <h2>{categoryName(group.name)}</h2>
            <div className="stack">
              {group.items.map(([id, item]) => (
                <div key={id} className={loom.tweaks.has(id) ? "row on" : "row"} onClick={() => loom.toggleSet("tweaks", id)} role="button" tabIndex={0} onKeyDown={(event) => { if (event.key === "Enter") loom.toggleSet("tweaks", id); }}>
                  <Check on={loom.tweaks.has(id)} />
                  <span>
                    <b>{item.Content}</b>
                    <p>{item.Description}</p>
                  </span>
                  <InfoButton label="Details" title={item.Content} kicker={categoryName(item.category)} body={item.Description} />
                </div>
              ))}
            </div>
          </section>
        ))}
        <section className="section">
          <h2>Preferences</h2>
          <div className="stack">
            {toggleTweaks.filter(([, item]) => matches(query, item.Content, item.Description)).map(([id, item]) => (
              <div className="row toggle" key={id}>
                <button className={live[id] ? "switch on" : "switch"} type="button" aria-pressed={!!live[id]} onClick={() => void flip(id, !live[id])} disabled={loom.busy}><i /></button>
                <span><b>{item.Content}</b><p>{item.Description}</p></span>
              </div>
            ))}
            {comboTweaks.map(([id, item]) => {
              const raw = item.ComboItems ?? "";
              const choices = (raw.includes("|") ? raw.split("|") : raw.split(/\s+/)).map((choice) => choice.trim()).filter(Boolean);
              const value = id === "WPFchangedns" ? loom.dns : (combos[id] || choices[0] || "");
              return (
                <div className="row" key={id}>
                  <span />
                  <span>
                    <b>{item.Content}</b>
                    <p>{item.ComboDescriptions?.[value] || item.Description || "Applied with the selected tweaks when this is DNS."}</p>
                  </span>
                  <select className="select" value={value} disabled={loom.busy} onChange={(event) => void chooseCombo(id, event.target.value)}>
                    {choices.map((choice) => <option key={choice}>{choice}</option>)}
                  </select>
                </div>
              );
            })}
            {buttonTweaks.map(([id, item]) => (
              <div className="row action" key={id}>
                <span>
                  <b>{item.Content}</b>
                  {item.Description ? <p>{item.Description}</p> : null}
                  {item.category.includes("NOT FOR LAPTOPS") ? <p className="warn">Desktop PCs only. Do not use this on a laptop.</p> : null}
                </span>
                <button className="btn" type="button" disabled={loom.busy} onClick={() => void loom.run("button", { key: id })}>Run</button>
              </div>
            ))}
          </div>
        </section>
      </div>
      <div className="dock">
        <div className="dock-bar">
          <strong>{loom.tweaks.size} selected</strong>
          <span className="grow" />
          <button className="btn" type="button" disabled={loom.busy || loom.tweaks.size === 0} onClick={() => void loom.run("apply-tweaks", { keys: [...loom.tweaks], undo: true, dns: "Default" })}>Undo</button>
          <button className="btn primary" type="button" disabled={loom.busy || (loom.tweaks.size === 0 && loom.dns === "Default")} onClick={() => void loom.run("apply-tweaks", { keys: [...loom.tweaks], undo: false, dns: loom.dns })}>Apply tweaks</button>
        </div>
      </div>
    </>
  );
}

function AdminNote() {
  return (
    <div className="banner">
      <span className="chip warn">Administrator</span>
      <span>These changes need Loom to be running as administrator.</span>
    </div>
  );
}

function buttonsIn(category: string) {
  return featureButtons.filter(([, item]) => item.category === category);
}

export function ConfigPage() {
  const loom = useLoom();
  const groups = grouped(selectableFeatures, (item: FeatureItem) => item.category, ["Features"]);
  const fixes = buttonsIn("Fixes");
  const panels = buttonsIn("Legacy Windows Panels");
  const remote = featureButtons.filter(([, item]) => item.category !== "Fixes" && item.category !== "Legacy Windows Panels" && item.category !== "Features");

  async function runFix(key: string, content: string) {
    if (key === "WPFPanelDISM") {
      const yes = await loom.ask({
        title: "Scan the system?",
        body: "This runs a disk check, System File Checker, and DISM. It can take a long time.",
        confirm: "Start scan",
      });
      if (!yes) return;
    }
    if (key === "WPFFixesUpdate") {
      const yes = await loom.ask({
        title: "Reset Windows Update?",
        body: "Loom stops the update services, clears the download cache, reregisters the update libraries, and starts discovery again.",
        confirm: "Reset update",
      });
      if (!yes) return;
    }
    await loom.run("button", { key, content });
  }

  return (
    <>
      <header className="page-head">
        <div>
          <h1>Config</h1>
          <p className="lede">Turn Windows features on, open the classic control panels, and run the same repair actions.</p>
        </div>
      </header>
      <div className="scroll">
        {!loom.info?.admin ? <AdminNote /> : null}
        {groups.map((group) => (
          <section className="section" key={group.name}>
            <h2>{categoryName(group.name)}</h2>
            <div className="stack">
              {group.items.map(([id, item]) => (
                <button key={id} className={loom.features.has(id) ? "row on" : "row"} type="button" onClick={() => loom.toggleSet("features", id)}>
                  <Check on={loom.features.has(id)} />
                  <span><b>{item.Content}</b><p>{item.Description}</p></span>
                  <span />
                </button>
              ))}
            </div>
          </section>
        ))}
        <section className="section">
          <h2>Fixes</h2>
          <div className="grid">
            {fixes.map(([id, item]) => (
              <article className="panel" key={id}>
                <h3>{item.Content}</h3>
                <p className="hint">{item.Description}</p>
                <button className="btn" type="button" disabled={loom.busy} onClick={() => void runFix(id, item.Content)}>Run</button>
              </article>
            ))}
            {remote.map(([id, item]) => (
              <article className="panel" key={id}>
                <h3>{item.Content}</h3>
                <p className="hint">{item.Description || item.category}</p>
                <button className="btn" type="button" disabled={loom.busy} onClick={() => void loom.run("button", { key: id })}>Run</button>
              </article>
            ))}
          </div>
        </section>
        <section className="section">
          <h2>Legacy panels</h2>
          <div className="tools">
            {panels.map(([id, item]) => (
              <button key={id} className="btn" type="button" onClick={() => void loom.run("button", { key: id })}>{item.Content}</button>
            ))}
          </div>
        </section>
      </div>
      <div className="dock">
        <div className="dock-bar">
          <strong>{loom.features.size} features</strong>
          <span className="grow" />
          <button className="btn primary" type="button" disabled={loom.busy || loom.features.size === 0} onClick={() => void loom.run("features", { keys: [...loom.features] })}>Enable features</button>
        </div>
      </div>
    </>
  );
}

export function UpdatesPage() {
  const loom = useLoom();
  async function disable() {
    const yes = await loom.ask({
      title: "Disable Windows Update?",
      body: "Security updates will not install until you restore the Windows defaults. Services are stopped and downloaded update files are cleared.",
      confirm: "Disable updates",
      danger: true,
    });
    if (!yes) return;
    await loom.run("updates", { profile: "disable", confirm: true });
  }
  return (
    <>
      <header className="page-head">
        <div>
          <h1>Updates</h1>
          <p className="lede">Choose how Windows receives updates. Each profile replaces the update settings Loom manages.</p>
        </div>
      </header>
      <div className="scroll">
        {!loom.info?.admin ? <AdminNote /> : null}
        <div className="profiles">
          <article className="profile">
            <div>
              <span className="chip good">Recommended</span>
              <h3>Balanced</h3>
              <p>Defers feature updates and keeps quality updates close behind.</p>
            </div>
            <ul>
              <li>Feature updates wait 365 days</li>
              <li>Quality updates wait 4 days</li>
              <li>Drivers stay out of quality updates</li>
              <li>Windows notifies before installing</li>
            </ul>
            <button className="btn primary" type="button" disabled={loom.busy} onClick={() => void loom.run("updates", { profile: "recommended" })}>Apply recommended</button>
          </article>
          <article className="profile">
            <div>
              <h3>Windows default</h3>
              <p>Hand update policy back to Windows.</p>
            </div>
            <ul>
              <li>Removes the policies Loom writes</li>
              <li>Restores the update services</li>
              <li>Turns the update tasks back on</li>
            </ul>
            <button className="btn" type="button" disabled={loom.busy} onClick={() => void loom.run("updates", { profile: "default" })}>Restore defaults</button>
          </article>
          <article className="profile">
            <div>
              <span className="chip warn">Advanced</span>
              <h3>Disable updates</h3>
              <p>For a machine you update some other way.</p>
            </div>
            <ul>
              <li>Turns off automatic update policy</li>
              <li>Stops update services and tasks</li>
              <li>Clears downloaded update files</li>
            </ul>
            <button className="btn danger" type="button" disabled={loom.busy} onClick={() => void disable()}>Disable updates</button>
          </article>
        </div>
      </div>
    </>
  );
}

export function AppsPage() {
  const loom = useLoom();
  const [query, setQuery] = useState("");
  const groups = grouped(
    entries(appx).filter(([, item]) => matches(query, item.Content, item.Description, item.PackageId)),
    (item) => item.Category,
  );
  return (
    <>
      <header className="page-head">
        <div>
          <h1>Inbox apps</h1>
          <p className="lede">Remove or restore the Microsoft Store apps that come with Windows.</p>
        </div>
        <input className="search" value={query} placeholder="Search apps" onChange={(event) => setQuery(event.target.value)} />
      </header>
      <div className="scroll">
        <div className="tools band">
          <button className="btn" type="button" onClick={() => loom.replaceSet("appx", presets.AppxDefault ?? [])}>Default removal</button>
          <button className="btn" type="button" onClick={() => loom.replaceSet("appx", Object.keys(appx))}>Select all</button>
          <button className="btn quiet" type="button" onClick={() => loom.replaceSet("appx", [])}>Clear</button>
          <button className="btn quiet" type="button" disabled={loom.busy} onClick={() => void loom.run("appx-installed").then((result) => result?.ok && loom.replaceSet("appx", asList(result.ids)))}>Select installed</button>
        </div>
        {groups.map((group) => (
          <section className="section" key={group.name}>
            <h2>{group.name}</h2>
            <div className="stack">
              {group.items.map(([id, item]) => (
                <button key={id} className={loom.appx.has(id) ? "row on" : "row"} type="button" onClick={() => loom.toggleSet("appx", id)}>
                  <Check on={loom.appx.has(id)} />
                  <span><b>{item.Content}</b><p>{item.Description}</p></span>
                  <span />
                </button>
              ))}
            </div>
          </section>
        ))}
      </div>
      <div className="dock">
        <div className="dock-bar">
          <strong>{loom.appx.size} selected</strong>
          <span className="grow" />
          <button className="btn" type="button" disabled={loom.busy || loom.appx.size === 0} onClick={() => void loom.run("appx", { mode: "install", ids: [...loom.appx] })}>Restore</button>
          <button className="btn danger" type="button" disabled={loom.busy || loom.appx.size === 0} onClick={() => void loom.run("appx", { mode: "remove", ids: [...loom.appx] })}>Remove</button>
        </div>
      </div>
    </>
  );
}

interface Edition { index: number; name: string; edition: string }
interface UsbDisk { number: number; name: string; sizeGb: number }

export function WindowsPage() {
  const loom = useLoom();
  const [step, setStep] = useState<"select" | "modify" | "output">("select");
  const [path, setPath] = useState("");
  const [letter, setLetter] = useState("");
  const [kind, setKind] = useState("");
  const [sizeGb, setSizeGb] = useState<number | null>(null);
  const [editions, setEditions] = useState<Edition[]>([]);
  const [editionIndex, setEditionIndex] = useState(1);
  const [inject, setInject] = useState(false);
  const [contents, setContents] = useState("");
  const [work, setWork] = useState("");
  const [disks, setDisks] = useState<UsbDisk[]>([]);
  const [disk, setDisk] = useState<number | null>(null);

  async function browse() {
    const selected = await pickIso();
    if (selected) {
      setPath(selected);
      setStep("select");
      setContents("");
    }
  }

  async function mount() {
    const result = await loom.run("iso-mount", { path });
    if (!result?.ok) return;
    const list = asList(result.editions) as Edition[];
    setEditions(list);
    setLetter(result.letter ?? "");
    setKind(result.kind ?? "");
    setSizeGb(result.sizeGb ?? null);
    if (list[0]) setEditionIndex(list[0].index);
    setStep("modify");
  }

  async function modify() {
    const chosen = editions.find((item) => item.index === editionIndex);
    const result = await loom.run("iso-modify", {
      path,
      index: editionIndex,
      edition: chosen?.edition ?? "",
      injectDrivers: inject,
    });
    if (!result?.ok || !result.contents) return;
    setContents(result.contents);
    setWork(result.work ?? "");
    setStep("output");
    const usb = await loom.run("iso-usb-list");
    if (usb?.ok) {
      const found = asList(usb.disks) as UsbDisk[];
      setDisks(found);
      setDisk(found[0]?.number ?? null);
    }
  }

  async function exportIso() {
    const output = await saveIso();
    if (!output) return;
    await loom.run("iso-export", { contents, output });
  }

  async function writeUsb() {
    const target = disks.find((item) => item.number === disk);
    if (!target) return;
    const yes = await loom.ask({
      title: `Erase disk ${target.number}?`,
      body: `Everything on ${target.name} (${target.sizeGb} GB) will be deleted and replaced with this Windows setup.`,
      confirm: "Erase and write",
      danger: true,
    });
    if (!yes) return;
    await loom.run("iso-usb-write", { contents, disk: target.number, confirm: true });
  }

  return (
    <>
      <header className="page-head">
        <div>
          <h1>Windows</h1>
          <p className="lede">Prepare a Windows 11 setup USB or ISO: local account, requirement bypass, and the staged first-logon cleanup.</p>
        </div>
      </header>
      <div className="steps">
        {(["select", "modify", "output"] as const).map((name, index) => (
          <span key={name} className={step === name ? "step on" : "step"}>{index + 1} {name === "select" ? "Select" : name === "modify" ? "Prepare" : "Save"}</span>
        ))}
      </div>
      <div className="scroll">
        {step === "select" ? (
          <div className="choice">
            <input className="field" value={path} placeholder="Path to a Windows ISO" onChange={(event) => setPath(event.target.value)} />
            <div className="tools">
              <button className="btn" type="button" onClick={() => void browse()}>Browse</button>
              <button className="btn primary" type="button" disabled={loom.busy || !path} onClick={() => void mount()}>Mount and read</button>
            </div>
            <p className="note">Loom mounts the ISO, reads the editions, then copies it to a working folder. Your original ISO stays unchanged.</p>
          </div>
        ) : null}
        {step === "modify" ? (
          <div className="choice">
            <p className="note">Mounted at {letter}: · {kind.toUpperCase()} · {sizeGb ?? "?"} GB</p>
            <select className="select" value={editionIndex} onChange={(event) => setEditionIndex(Number(event.target.value))}>
              {editions.map((item) => <option key={item.index} value={item.index}>{item.index}: {item.name}</option>)}
            </select>
            <label className="option"><input type="checkbox" checked={inject} onChange={(event) => setInject(event.target.checked)} /> Inject this PC's drivers into the setup image</label>
            <div className="note">
              The answer file bypasses the TPM, Secure Boot, CPU, RAM, and storage checks, offers a local account, and stages removal of the inbox apps, OneDrive setup, and Copilot on first logon. The edition you pick is pinned so Setup keeps it.
            </div>
            <div className="tools">
              <button className="btn" type="button" onClick={() => setStep("select")}>Back</button>
              <button className="btn primary" type="button" disabled={loom.busy} onClick={() => void modify()}>Prepare setup</button>
            </div>
          </div>
        ) : null}
        {step === "output" ? (
          <div className="choice">
            <p className="note">Setup files are ready. Save an ISO, or write a USB drive. USB writing erases the selected disk.</p>
            <div className="tools">
              <button className="btn primary" type="button" disabled={loom.busy} onClick={() => void exportIso()}>Save ISO</button>
              <button className="btn" type="button" disabled={loom.busy} onClick={() => void loom.run("iso-clean", { path, work }).then(() => { setStep("select"); setContents(""); })}>Discard working files</button>
            </div>
            <select className="select" value={disk ?? ""} onChange={(event) => setDisk(Number(event.target.value))}>
              {disks.length === 0 ? <option value="">No USB drives</option> : null}
              {disks.map((item) => <option key={item.number} value={item.number}>Disk {item.number}: {item.name} ({item.sizeGb} GB)</option>)}
            </select>
            <button className="btn danger" type="button" disabled={loom.busy || disk == null} onClick={() => void writeUsb()}>Write USB</button>
          </div>
        ) : null}
      </div>
    </>
  );
}
