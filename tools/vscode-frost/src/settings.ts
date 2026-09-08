// Copyright 2026 Two Sigma Open Source, LLC
// SPDX-License-Identifier: Apache-2.0
import * as path from "node:path";
import * as vscode from "vscode";
import { pickDebugTarget, readRepositoryMetadata, PlainLoadSelection } from "./plainLoad";

export interface FrostSettings {
  repoRoot: string;
  pythonPath: string;
  openocdPath: string;
  gdbPath: string;
  vivadoPath: string;
  hwServerPath: string;
  jtagSerial: string;
  vivadoTarget: string;
  app: string;
  coremarkMode?: "performance" | "validation";
  memory: "bram" | "ddr";
  cpuClockHz: number;
  bitstream: string;
  elf: string;
  elfExplicit?: boolean;
  startupTimeoutMs: number;
  toolTimeoutMs: number;
  registerDescription: "default" | "core";
}

function textSetting(config: vscode.WorkspaceConfiguration, key: string, fallback: string): string {
  const value: unknown = config.get(key, fallback);
  if (typeof value !== "string" || /[\0\r\n]/.test(value)) {
    throw new Error(`frost.${key} must be a single-line string.`);
  }
  return value.trim();
}

function requiredText(config: vscode.WorkspaceConfiguration, key: string, fallback = ""): string {
  const value = textSetting(config, key, fallback);
  if (!value) {
    throw new Error(`Set frost.${key} on the FPGA host first (FROST: Configure Target or Settings).`);
  }
  return value;
}

function choice<T extends string>(config: vscode.WorkspaceConfiguration, key: string, choices: readonly T[]): T {
  const value = textSetting(config, key, choices[0]);
  if (!choices.includes(value as T)) {
    throw new Error(`frost.${key} must be one of: ${choices.join(", ")}.`);
  }
  return value as T;
}

function positiveInteger(config: vscode.WorkspaceConfiguration, key: string, fallback: number, maximum = Number.MAX_SAFE_INTEGER): number {
  const value: unknown = config.get(key, fallback);
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new Error(`frost.${key} must be an explicit positive integer${maximum < Number.MAX_SAFE_INTEGER ? ` no greater than ${maximum}` : ""}.`);
  }
  return value;
}

export function validateVivadoTarget(value: string): string | undefined {
  if (value && (!/^127\.0\.0\.1:3121\/xilinx_tcf\/[^\s/*?]+\/[^\s/*?]+$/.test(value) || /[\0\r\n]/.test(value))) {
    return "Use the exact full path at 127.0.0.1:3121/xilinx_tcf/vendor/serial (no wildcard, target index or hostname alias).";
  }
  return undefined;
}

export function validateJtagSerial(value: string): string | undefined {
  return /^[A-Za-z0-9_-]+$/.test(value) ? undefined : "Use an exact FTDI serial containing only letters, digits, underscores or hyphens.";
}

export function getSettings(folder: vscode.WorkspaceFolder): FrostSettings {
  const config = vscode.workspace.getConfiguration("frost", folder.uri);
  const repoRoot = path.resolve(folder.uri.fsPath, textSetting(config, "repoRoot", ""));
  const app = textSetting(config, "app", "hello_world");
  if (!/^[a-z][a-z0-9_]*$/.test(app)) {
    throw new Error("frost.app must be a repository application name.");
  }
  const vivadoTarget = textSetting(config, "vivadoTarget", "");
  const targetError = validateVivadoTarget(vivadoTarget);
  if (targetError) {
    throw new Error(targetError);
  }
  const bitstream = textSetting(config, "bitstream", "");
  if (bitstream && path.extname(bitstream) !== ".bit") {
    throw new Error("frost.bitstream must select a .bit file.");
  }
  const explicitElf = textSetting(config, "elf", "");
  const elf = explicitElf || `sw/apps/${app}/sw.elf`;
  const jtagSerial = requiredText(config, "jtagSerial");
  const serialError = validateJtagSerial(jtagSerial);
  if (serialError) { throw new Error(serialError); }
  return {
    repoRoot,
    pythonPath: requiredText(config, "pythonPath", "python3"),
    openocdPath: requiredText(config, "openocdPath", "openocd"),
    gdbPath: requiredText(config, "gdbPath", "riscv-none-elf-gdb"),
    vivadoPath: requiredText(config, "vivadoPath", "vivado"),
    hwServerPath: requiredText(config, "hwServerPath", "hw_server"),
    jtagSerial,
    vivadoTarget,
    app,
    coremarkMode: choice(config, "coremarkProMode", ["validation", "performance"] as const),
    memory: choice(config, "memory", ["bram", "ddr"] as const),
    cpuClockHz: positiveInteger(config, "cpuClockHz", 0),
    bitstream: bitstream ? path.resolve(repoRoot, bitstream) : "",
    elf: path.resolve(repoRoot, elf),
    elfExplicit: !!explicitElf,
    startupTimeoutMs: positiveInteger(config, "startupTimeoutMs", 20000, 2147483647),
    toolTimeoutMs: positiveInteger(config, "toolTimeoutMs", 300000, 2147483647),
    registerDescription: choice(config, "registerDescription", ["default", "core"] as const),
  };
}

export async function configureTarget(folder: vscode.WorkspaceFolder): Promise<boolean> {
  const config = vscode.workspace.getConfiguration("frost", folder.uri);
  const jtagSerial = await vscode.window.showInputBox({
    title: "FROST target on this host",
    prompt: "Exact FT4232H JTAG bridge serial",
    value: config.get<string>("jtagSerial", ""),
    ignoreFocusOut: true,
    validateInput: value => validateJtagSerial(value.trim()),
  });
  if (jtagSerial === undefined) { return false; }
  const vivadoTarget = await vscode.window.showInputBox({
    title: "FROST Vivado target",
    prompt: "127.0.0.1:3121/xilinx_tcf/Xilinx/<serial+channel>; leave empty for attach-only use",
    value: config.get<string>("vivadoTarget", ""),
    ignoreFocusOut: true,
    validateInput: value => validateVivadoTarget(value.trim()),
  });
  if (vivadoTarget === undefined) { return false; }
  const metadata = await readRepositoryMetadata({
    repoRoot: path.resolve(folder.uri.fsPath, textSetting(config, "repoRoot", "")),
    pythonPath: requiredText(config, "pythonPath", "python3"),
    startupTimeoutMs: positiveInteger(config, "startupTimeoutMs", 20000, 2147483647),
  });
  const selected = await pickDebugTarget({
    app: textSetting(config, "app", "hello_world"),
    memory: choice(config, "memory", ["bram", "ddr"] as const),
    cpuClockHz: config.get<number>("cpuClockHz", 0),
    coremarkMode: choice(config, "coremarkProMode", ["validation", "performance"] as const),
  }, metadata);
  if (!selected) { return false; }
  const values = { jtagSerial: jtagSerial.trim(), vivadoTarget: vivadoTarget.trim(),
    cpuClockHz: selected.cpuClockHz, app: selected.app, memory: selected.memory,
    ...(selected.coremarkMode ? { coremarkProMode: selected.coremarkMode } : {}) };
  for (const [key, value] of Object.entries(values)) {
    await config.update(key, value, selectionTarget(config, key));
  }
  void vscode.window.showInformationMessage("FROST target saved. Tool paths and artifact choices are available in Settings (FROST).");
  return true;
}

export async function saveDebugSelection(folder: vscode.WorkspaceFolder, selected: PlainLoadSelection): Promise<void> {
  const config = vscode.workspace.getConfiguration("frost", folder.uri);
  for (const [key, value] of Object.entries({ app: selected.app, memory: selected.memory,
    cpuClockHz: selected.cpuClockHz,
    ...(selected.coremarkMode ? { coremarkProMode: selected.coremarkMode } : {}) })) {
    await config.update(key, value, selectionTarget(config, key));
  }
}

// Existing resource overrides must change at their effective scope, otherwise
// a later Attach would silently use the old application and the wrong ELF.
function selectionTarget(config: vscode.WorkspaceConfiguration, key: string): vscode.ConfigurationTarget {
  if (["app", "memory", "cpuClockHz", "coremarkProMode"].includes(key)) {
    const values = config.inspect(key);
    if (values?.workspaceFolderValue !== undefined) return vscode.ConfigurationTarget.WorkspaceFolder;
    if (values?.workspaceValue !== undefined) return vscode.ConfigurationTarget.Workspace;
  }
  return vscode.ConfigurationTarget.Global;
}
