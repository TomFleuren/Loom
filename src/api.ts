export interface LogLine {
  level: string;
  message: string;
  percent: number;
}

export interface EngineResult {
  ok?: boolean;
  error?: string;
  ids?: string[] | string;
  results?: unknown;
  editions?: unknown;
  disks?: unknown;
  letter?: string;
  kind?: string;
  sizeGb?: number;
  contents?: string;
  work?: string;
  output?: string;
  count?: number;
  toggles?: Record<string, boolean>;
  combos?: Record<string, string | null>;
  windows?: string;
  admin?: boolean;
  winget?: boolean;
  choco?: boolean;
}

export interface AppInfo {
  mode: "app" | "setup" | "uninstall";
  version: string;
  admin: boolean;
  installed: boolean;
  installPath: string;
  exe: string;
}

export function isTauri() {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function asList<T>(value: T[] | T | null | undefined): T[] {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
}

export async function getAppInfo(): Promise<AppInfo> {
  if (!isTauri()) {
    return {
      mode: "app",
      version: "1.0.0",
      admin: false,
      installed: false,
      installPath: "C:\\Program Files\\Loom",
      exe: "",
    };
  }
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<AppInfo>("app_info");
}

export async function elevate(mode: AppInfo["mode"]) {
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("elevate", { mode });
}

export async function installLoom(desktop: boolean, startMenu: boolean) {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<string>("install_loom", { desktop, startMenu });
}

export async function uninstallLoom() {
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("uninstall_loom");
}

export async function engine<T>(action: string, payload: unknown, onLog: (line: LogLine) => void): Promise<T> {
  if (!isTauri()) {
    onLog({ level: "INFO", message: `Preview only. ${action} is not applied from the browser.`, percent: 100 });
    return { ok: true, ids: [], editions: [], disks: [], toggles: {}, combos: {} } as T;
  }
  const { invoke } = await import("@tauri-apps/api/core");
  const { listen } = await import("@tauri-apps/api/event");
  const unlisten = await listen<LogLine>("engine-log", (event) => onLog(event.payload));
  try {
    return await invoke<T>("run_engine", { action, payload });
  } finally {
    unlisten();
  }
}

export async function pickIso() {
  if (!isTauri()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const selected = await open({
    multiple: false,
    filters: [{ name: "Windows ISO", extensions: ["iso"] }],
  });
  return typeof selected === "string" ? selected : null;
}

export async function saveTextFile(name: string, contents: string) {
  if (!isTauri()) {
    const blob = new Blob([contents], { type: "application/json" });
    const link = document.createElement("a");
    const href = URL.createObjectURL(blob);
    link.href = href;
    link.download = name;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(href), 1500);
    return name;
  }
  const { save } = await import("@tauri-apps/plugin-dialog");
  const path = await save({
    defaultPath: name,
    filters: [{ name: "JSON", extensions: ["json"] }],
  });
  if (!path) return null;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("write_text", { path, contents });
  return path;
}

export async function saveIso() {
  if (!isTauri()) return null;
  const { save } = await import("@tauri-apps/plugin-dialog");
  return save({
    defaultPath: "Loom-Windows.iso",
    filters: [{ name: "Windows ISO", extensions: ["iso"] }],
  });
}

export async function openUrl(url: string) {
  if (!isTauri()) {
    window.open(url, "_blank");
    return;
  }
  const { openUrl: open } = await import("@tauri-apps/plugin-opener");
  await open(url);
}
