import applicationsJson from "./data/applications.json";
import appxJson from "./data/appx.json";
import featuresJson from "./data/feature.json";
import presetsJson from "./data/preset.json";
import tweaksJson from "./data/tweaks.json";

export interface AppItem {
  category: string;
  choco?: string;
  content: string;
  description: string;
  link: string;
  winget?: string;
  foss?: boolean;
}

export interface RegistryValue {
  Path: string;
  Name: string;
  Type?: string;
  Value?: string;
  OriginalValue?: string;
  DefaultState?: string;
  DefaultValue?: string;
  Values?: Record<string, string>;
}

export interface TweakItem {
  Content: string;
  Description?: string;
  category: string;
  panel?: string;
  Type?: string;
  ComboItems?: string;
  ComboDescriptions?: Record<string, string>;
  registry?: RegistryValue[];
  link?: string;
}

export interface FeatureItem {
  Content: string;
  Description?: string;
  category: string;
  panel?: string;
  Type?: string;
  feature?: string[];
  InvokeScript?: string[];
  link?: string;
}

export interface AppxItem {
  Category: string;
  Content: string;
  Description: string;
  PackageId: string;
  StoreId?: string;
}

export const apps = applicationsJson as unknown as Record<string, AppItem>;
export const tweaks = tweaksJson as unknown as Record<string, TweakItem>;
export const features = featuresJson as unknown as Record<string, FeatureItem>;
export const appx = appxJson as unknown as Record<string, AppxItem>;
export const presets = presetsJson as unknown as Record<string, string[]>;

export const appCategories = [
  "Browsers",
  "Communications",
  "Development",
  "Document",
  "Games",
  "Microsoft Tools",
  "Multimedia Tools",
  "Pro Tools",
  "Selfhosted Tools",
  "Utilities",
];

export const tweakCategories = [
  "Essential Tweaks",
  "Customize Preferences",
  "Performance Plans - NOT FOR LAPTOPS",
  "z__Advanced Tweaks - CAUTION",
];

export function entries<T>(record: Record<string, T>): [string, T][] {
  return Object.entries(record);
}

export function categoryName(value: string) {
  return value.replace(/^_+/, "").replace(/^z__/, "");
}

export function matches(query: string, ...parts: Array<string | undefined>) {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  return parts.some((part) => (part ?? "").toLowerCase().includes(needle));
}

export function grouped<T>(list: [string, T][], categoryOf: (item: T) => string, order: string[] = []) {
  const buckets = new Map<string, [string, T][]>();
  for (const entry of list) {
    const name = categoryOf(entry[1]) || "Other";
    const current = buckets.get(name) ?? [];
    current.push(entry);
    buckets.set(name, current);
  }
  const names = [...buckets.keys()].sort((a, b) => {
    const ai = order.indexOf(a);
    const bi = order.indexOf(b);
    if (ai === -1 && bi === -1) return a.localeCompare(b);
    if (ai === -1) return 1;
    if (bi === -1) return -1;
    return ai - bi;
  });
  return names.map((name) => ({ name, items: buckets.get(name) ?? [] }));
}

export const featureList = entries(features);
export const selectableFeatures = featureList.filter(([, item]) => item.Type !== "Button" && (item.feature?.length ?? 0) > 0);
export const featureButtons = featureList.filter(([, item]) => item.Type === "Button" && item.Content !== "Install Features");
export const tweakList = entries(tweaks);
export const checkboxTweaks = tweakList.filter(([, item]) => !item.Type || item.Type === "CheckBox");
export const toggleTweaks = tweakList.filter(([, item]) => item.Type === "Toggle");
export const comboTweaks = tweakList.filter(([, item]) => item.Type === "Combobox");
export const buttonTweaks = tweakList.filter(([, item]) => item.Type === "Button");
