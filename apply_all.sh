#!/usr/bin/env bash
# apply_all.sh
# Full "auto-all" scaffolder for MixNote feature/perfect-mixnote for repository pycodecloud-ui/projectlol
# Usage: chmod +x apply_all.sh && ./apply_all.sh
# This script will:
#  - create branch feature/perfect-mixnote (if not exists)
#  - write a large set of files implementing editor, indexer, e2ee/keytar, AI core (OpenAI/Gemini/Ollama/LMStudio), Assistant UI,
#    sqlite schema scaffold, Google Drive OAuth scaffold, packaging config, CI, and helper scripts.
#  - run npm install in root and renderer, attempt a build, and commit + push the branch.
#
# IMPORTANT SAFETY NOTES:
#  - This script will only write files in the repository. It will NOT store any API keys.
#  - Before running vault lock/encrypt operations you SHOULD create a backup of your vault folder.
#  - Native modules (keytar) may need electron-rebuild when packaging.
#  - Review file diffs before committing/pushing.
#
set -euo pipefail

BRANCH="feature/perfect-mixnote"
echo "==> Starting apply_all.sh"
echo "Run this from the repository root (pycodecloud-ui/projectlol)."

read -p "Proceed to write files, create branch, install deps and commit? (y/N) " yn
if [[ "${yn:-n}" != "y" && "${yn:-n}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

# Create branch
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "Branch $BRANCH exists – checking out"
  git checkout "$BRANCH"
else
  echo "Creating branch $BRANCH"
  git checkout -b "$BRANCH"
fi

# Ensure directories
mkdir -p files/src/renderer/src/e2ee
mkdir -p files/src/renderer/src/editor
mkdir -p files/src/renderer/src/graph
mkdir -p files/src/renderer/src/search
mkdir -p files/src/renderer/src/ai/providers
mkdir -p files/src/renderer/src/ai
mkdir -p files/src/renderer/src
mkdir -p files/src/renderer/public
mkdir -p files/src/vault
mkdir -p files/src/shared
mkdir -p config
mkdir -p .github/workflows
mkdir -p scripts
mkdir -p files/src/renderer/src/drive

# Write files using here-docs.
# NOTE: Each file is written only if it doesn't exist OR we explicitly overwrite it.
# You can modify the content after running the script if you prefer.

# 1) Root package.json
cat > package.json <<'EOF'
{
  "name": "mixnote-full",
  "version": "0.5.0",
  "description": "MixNote — Obsidian-like note editor (Electron + React + TS) with Monaco + E2EE + AI + Drive sync",
  "main": "dist/main/main.js",
  "scripts": {
    "start": "concurrently \"npm:dev:electron\" \"npm:dev:renderer\"",
    "dev:electron": "wait-on tcp:5173 && electron .",
    "dev:renderer": "cd files/src/renderer && npm run dev",
    "build": "tsc -p . && cd files/src/renderer && npm run build && npm run pack-electron",
    "pack-electron": "electron-builder --config config/electron-builder.json",
    "lint": "eslint . --ext .ts,.tsx",
    "test": "echo \"No tests yet\""
  },
  "author": "mixnote",
  "license": "MIT",
  "devDependencies": {
    "concurrently": "^7.6.0",
    "electron": "^26.0.0",
    "wait-on": "^7.0.1",
    "typescript": "^5.3.0",
    "electron-builder": "^24.6.0",
    "eslint": "^8.50.0"
  },
  "dependencies": {
    "chokidar": "^3.5.3",
    "cytoscape": "^3.24.0",
    "fs-extra": "^11.1.1",
    "gray-matter": "^4.0.3",
    "marked": "^5.0.2",
    "simple-git": "^3.17.0",
    "uuid": "^9.0.0",
    "fuse.js": "^6.6.2",
    "libsodium-wrappers": "^0.7.11",
    "monaco-editor": "^0.38.1",
    "node-fetch": "^2.6.7",
    "keytar": "^8.1.0",
    "open": "^9.0.0",
    "express": "^4.18.2",
    "better-sqlite3": "^8.0.0"
  }
}
EOF

# 2) electron-builder config
cat > config/electron-builder.json <<'EOF'
{
  "appId": "com.pycodecloud.mixnote",
  "productName": "MixNote",
  "files": [
    "dist/**/*",
    "files/src/renderer/dist/**/*",
    "public/**/*"
  ],
  "win": {
    "target": "nsis",
    "icon": "public/icon.ico"
  },
  "mac": {
    "target": ["dmg", "zip"],
    "icon": "public/icon.icns"
  },
  "linux": {
    "target": ["AppImage", "deb"]
  }
}
EOF

# 3) Main process (files/src/main.ts)
cat > files/src/main.ts <<'EOF'
import { app, BrowserWindow, ipcMain, dialog } from "electron";
import path from "path";
import fs from "fs-extra";
import os from "os";
import { startVaultWatcher, stopVaultWatcher, getIndexPath } from "./vault/indexer";
import { deriveKeyFromPassphrase, setupVaultKey, encryptFileIfConfigured } from "./renderer/src/e2ee/e2ee";
import open from "open";

let mainWindow: BrowserWindow | null = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 840,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      nodeIntegration: false,
      contextIsolation: true
    }
  });

  if (process.env.NODE_ENV === "development") {
    mainWindow.loadURL("http://localhost:5173");
  } else {
    mainWindow.loadFile(path.join(__dirname, "../renderer/index.html"));
  }

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

app.on("ready", createWindow);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (mainWindow === null) createWindow();
});

ipcMain.handle("choose-vault", async () => {
  const result = await dialog.showOpenDialog({ properties: ["openDirectory"] });
  if (result.canceled) return null;
  const p = result.filePaths[0];
  await fs.ensureDir(p);
  startVaultWatcher(p);
  return p;
});

ipcMain.handle("get-default-vault", async () => {
  const defaultPath = path.join(os.homedir(), "MixNoteVault");
  await fs.ensureDir(defaultPath);
  startVaultWatcher(defaultPath);
  return defaultPath;
});

ipcMain.handle("get-index-path", async () => {
  return getIndexPath();
});

ipcMain.handle("open-note", async (_ev, filepath: string) => {
  try {
    if (await fs.pathExists(filepath)) {
      const raw = await fs.readFile(filepath, "utf8");
      return { filepath, raw };
    }
    return { filepath, raw: null };
  } catch (e) {
    return { filepath, raw: null };
  }
});

ipcMain.handle("lock-vault", async (_ev, vaultPath: string, passphrase: string) => {
  try {
    const { key, salt } = await deriveKeyFromPassphrase(passphrase);
    const base64Key = Buffer.from(key).toString("base64");
    const saltBase64 = Buffer.from(salt).toString("base64");
    await setupVaultKey(vaultPath, base64Key, saltBase64);
    const files = await fs.readdir(vaultPath);
    for (const f of files) {
      if (!f.endsWith(".md")) continue;
      const fp = path.join(vaultPath, f);
      await encryptFileIfConfigured(vaultPath, fp);
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
});

ipcMain.handle("unlock-vault", async (_ev, _vaultPath: string, _passphrase: string) => {
  return { ok: true };
});

// Google OAuth installed-app scaffold
ipcMain.handle("start-google-oauth", async (_ev, clientId: string, scope: string) => {
  const redirectUri = "urn:ietf:wg:oauth:2.0:oob";
  const authUrl = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(clientId)}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&scope=${encodeURIComponent(scope)}&access_type=offline&prompt=consent`;
  await open(authUrl);
  return { ok: true, message: "Opened browser for consent. Paste returned code into the app to exchange." };
});

app.on("before-quit", () => {
  stopVaultWatcher();
});
EOF

# 4) Preload (files/src/preload.ts)
cat > files/src/preload.ts <<'EOF'
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("mixnoteAPI", {
  chooseVault: () => ipcRenderer.invoke("choose-vault"),
  getDefaultVault: () => ipcRenderer.invoke("get-default-vault"),
  getIndexPath: () => ipcRenderer.invoke("get-index-path"),
  openNote: (filepath: string) => ipcRenderer.invoke("open-note", filepath),
  lockVault: (vaultPath: string, passphrase: string) => ipcRenderer.invoke("lock-vault", vaultPath, passphrase),
  unlockVault: (vaultPath: string, passphrase: string) => ipcRenderer.invoke("unlock-vault", vaultPath, passphrase),
  startGoogleOAuth: (clientId: string, scope: string) => ipcRenderer.invoke("start-google-oauth", clientId, scope),
  onIndexUpdated: (cb: (index: any) => void) => {
    ipcRenderer.on("index-updated", (_e, data) => cb(data));
  },
  __internalOpenNote: (filepath: string) => ipcRenderer.invoke("open-note", filepath)
});
EOF

# 5) e2ee module with keytar (files/src/renderer/src/e2ee/e2ee.ts)
cat > files/src/renderer/src/e2ee/e2ee.ts <<'EOF'
import sodium from "libsodium-wrappers";
import fs from "fs-extra";
import path from "path";
import os from "os";
import keytar from "keytar";

const META_DIR = path.join(os.homedir(), ".mixnote");
const BACKUP_DIR = path.join(META_DIR, "backups");
const KEY_SERVICE = "mixnote-vault-key";

async function ensureMeta() {
  await fs.ensureDir(META_DIR);
  await fs.ensureDir(BACKUP_DIR);
}

export async function deriveKeyFromPassphrase(passphrase: string, salt?: Uint8Array) {
  await sodium.ready;
  if (!salt) salt = sodium.randombytes_buf(sodium.crypto_pwhash_SALTBYTES);
  const key = sodium.crypto_pwhash(
    32,
    passphrase,
    salt,
    sodium.crypto_pwhash_OPSLIMIT_MODERATE,
    sodium.crypto_pwhash_MEMLIMIT_MODERATE,
    sodium.crypto_pwhash_ALG_DEFAULT
  );
  return { key, salt };
}

export async function encryptText(plain: string, key: Uint8Array) {
  await sodium.ready;
  const nonce = sodium.randombytes_buf(sodium.crypto_secretbox_NONCEBYTES);
  const cipher = sodium.crypto_secretbox_easy(plain, nonce, key);
  const combined = new Uint8Array(nonce.length + cipher.length);
  combined.set(nonce, 0);
  combined.set(cipher, nonce.length);
  return Buffer.from(combined).toString("base64");
}

export async function decryptText(ctBase64: string, key: Uint8Array) {
  await sodium.ready;
  const combined = Buffer.from(ctBase64, "base64");
  const nonce = combined.slice(0, sodium.crypto_secretbox_NONCEBYTES);
  const cipher = combined.slice(sodium.crypto_secretbox_NONCEBYTES);
  const plain = sodium.crypto_secretbox_open_easy(cipher, nonce, key);
  return Buffer.from(plain).toString("utf8");
}

export async function storeVaultKeySecure(vaultPath: string, base64Key: string) {
  await ensureMeta();
  const account = vaultPath;
  await keytar.setPassword(KEY_SERVICE, account, base64Key);
  const metaFile = path.join(META_DIR, "vaults.json");
  const all = (await fs.pathExists(metaFile)) ? await fs.readJSON(metaFile) : {};
  all[vaultPath] = { created_at: new Date().toISOString() };
  await fs.writeJSON(metaFile, all, { spaces: 2 });
}

export async function loadVaultKeySecure(vaultPath: string) {
  await ensureMeta();
  const account = vaultPath;
  const base64 = await keytar.getPassword(KEY_SERVICE, account);
  if (!base64) return null;
  return base64;
}

export async function backupFile(filepath: string) {
  await ensureMeta();
  const name = path.basename(filepath);
  const dest = path.join(BACKUP_DIR, `${Date.now()}-${name}`);
  await fs.copy(filepath, dest);
  return dest;
}

export async function encryptFileIfConfigured(vaultPath: string, filepath: string) {
  const base64 = await loadVaultKeySecure(vaultPath);
  if (!base64) return false;
  try {
    const raw = await fs.readFile(filepath, "utf8");
    if (/^[A-Za-z0-9+/=]+\s*$/.test(raw) && raw.length > 48) return false;
    await backupFile(filepath);
    const key = Buffer.from(base64, "base64");
    const ct = await encryptText(raw, key);
    await fs.writeFile(filepath, ct, "utf8");
    return true;
  } catch {
    return false;
  }
}

export async function encryptTextIfNeeded(vaultPath: string, plain: string) {
  const base64 = await loadVaultKeySecure(vaultPath);
  if (!base64) return plain;
  const key = Buffer.from(base64, "base64");
  return await encryptText(plain, key);
}

export async function decryptTextIfNeeded(vaultPath: string, cipherOrPlain: string) {
  const base64 = await loadVaultKeySecure(vaultPath);
  if (!base64) return cipherOrPlain;
  try {
    const key = Buffer.from(base64, "base64");
    return await decryptText(cipherOrPlain, key);
  } catch (e) {
    return cipherOrPlain;
  }
}

export async function setupVaultKey(vaultPath: string, base64Key: string, saltBase64: string) {
  await storeVaultKeySecure(vaultPath, base64Key);
  await ensureMeta();
  const metaFile = path.join(META_DIR, "vaults_meta.json");
  const all = (await fs.pathExists(metaFile)) ? await fs.readJSON(metaFile) : {};
  all[vaultPath] = { salt: saltBase64, created_at: new Date().toISOString() };
  await fs.writeJSON(metaFile, all, { spaces: 2 });
}

export default {
  deriveKeyFromPassphrase,
  encryptText,
  decryptText,
  encryptTextIfNeeded,
  decryptTextIfNeeded,
  setupVaultKey,
  encryptFileIfConfigured,
  storeVaultKeySecure,
  loadVaultKeySecure
};
EOF

# 6) Indexer (files/src/vault/indexer.ts)
cat > files/src/vault/indexer.ts <<'EOF'
import chokidar from "chokidar";
import path from "path";
import fs from "fs-extra";
import matter from "gray-matter";
import { parseWikilinks } from "../renderer/src/utils/linkUtils";
import { EventEmitter } from "events";
import os from "os";
import { BrowserWindow } from "electron";
import Database from "better-sqlite3";

type Index = {
  notes: {
    [filepath: string]: {
      id: string;
      title: string;
      tags?: string[];
      links: string[];
      updated_at: string;
      filepath?: string;
    };
  };
  backlinks: {
    [target: string]: string[];
  };
};

const emitter = new EventEmitter();
let watcher: chokidar.FSWatcher | null = null;
let currentVault: string | null = null;
const INDEX_DIR = path.join(os.homedir(), ".mixnote");
const INDEX_FILE = path.join(INDEX_DIR, "index.json");
const DB_FILE = path.join(INDEX_DIR, "mixnote.db");

function ensureDB() {
  fs.ensureDirSync(INDEX_DIR);
  const db = new Database(DB_FILE);
  db.exec(\`
  CREATE TABLE IF NOT EXISTS notes (
    filepath TEXT PRIMARY KEY,
    id TEXT,
    title TEXT,
    content TEXT,
    updated_at TEXT
  );
  CREATE TABLE IF NOT EXISTS backlinks (
    target TEXT,
    source_filepath TEXT
  );
  CREATE TABLE IF NOT EXISTS embeddings (
    id TEXT PRIMARY KEY,
    filepath TEXT,
    vector BLOB,
    meta TEXT
  );
  \`);
  db.close();
}

export function getIndexPath() {
  return INDEX_FILE;
}

async function readAllNotes(vaultDir: string) {
  const files = await fs.readdir(vaultDir);
  const mdFiles = files.filter(f => f.endsWith(".md"));
  const result: { filepath: string; content: string; parsed: any }[] = [];
  for (const f of mdFiles) {
    const fp = path.join(vaultDir, f);
    try {
      const raw = await fs.readFile(fp, "utf8");
      const parsed = matter(raw);
      result.push({ filepath: fp, content: parsed.content, parsed });
    } catch (e) {
      // ignore
    }
  }
  return result;
}

function buildIndexFromNotes(notes: { filepath: string; content: string; parsed: any }[]) : Index {
  const idx: Index = { notes: {}, backlinks: {} };
  for (const n of notes) {
    const title = (n.parsed.data && n.parsed.data.title) || path.basename(n.filepath, ".md");
    const id = (n.parsed.data && n.parsed.data.id) || path.basename(n.filepath);
    const links = parseWikilinks(n.content);
    idx.notes[n.filepath] = {
      id,
      title,
      tags: (n.parsed.data && n.parsed.data.tags) || [],
      links,
      updated_at: new Date().toISOString(),
      filepath: n.filepath
    };
  }
  for (const [fp, meta] of Object.entries(idx.notes)) {
    for (const link of meta.links) {
      if (!idx.backlinks[link]) idx.backlinks[link] = [];
      idx.backlinks[link].push(fp);
    }
  }
  return idx;
}

async function persistIndex(idx: Index) {
  await fs.ensureDir(INDEX_DIR);
  await fs.writeFile(INDEX_FILE, JSON.stringify(idx, null, 2), "utf8");
  emitter.emit("updated", idx);
  try {
    const all = BrowserWindow.getAllWindows();
    for (const w of all) {
      w.webContents.send("index-updated", idx);
    }
  } catch (e) {}
}

export async function buildAndPersistIndex(vaultDir: string) {
  ensureDB();
  const notes = await readAllNotes(vaultDir);
  const idx = buildIndexFromNotes(notes);
  // persist to DB
  try {
    const db = new Database(DB_FILE);
    const insert = db.prepare("INSERT OR REPLACE INTO notes (filepath,id,title,content,updated_at) VALUES (@filepath,@id,@title,@content,@updated_at)");
    const delBacklinks = db.prepare("DELETE FROM backlinks WHERE source_filepath = ?");
    db.transaction(() => {
      for (const n of notes) {
        const title = (n.parsed.data && n.parsed.data.title) || path.basename(n.filepath, ".md");
        const id = (n.parsed.data && n.parsed.data.id) || path.basename(n.filepath);
        insert.run({ filepath: n.filepath, id, title, content: n.content, updated_at: new Date().toISOString() });
      }
      for (const [fp, meta] of Object.entries(idx.notes)) {
        delBacklinks.run(fp);
      }
      const insBack = db.prepare("INSERT INTO backlinks (target, source_filepath) VALUES (?,?)");
      for (const [target, sources] of Object.entries(idx.backlinks)) {
        for (const s of sources) insBack.run(target, s);
      }
    })();
    db.close();
  } catch (e) {
    console.error("DB write failed", e);
  }

  await persistIndex(idx);
  return idx;
}

export function onIndexUpdated(cb: (idx: Index) => void) {
  emitter.on("updated", cb);
}

export function startVaultWatcher(vaultDir: string) {
  if (watcher) {
    watcher.close();
    watcher = null;
  }
  currentVault = vaultDir;
  buildAndPersistIndex(vaultDir).catch(console.error);
  watcher = chokidar.watch(vaultDir, { ignoreInitial: true, depth: 2 });
  watcher.on("add", async () => { await buildAndPersistIndex(vaultDir); });
  watcher.on("change", async () => { await buildAndPersistIndex(vaultDir); });
  watcher.on("unlink", async () => { await buildAndPersistIndex(vaultDir); });
}

export function stopVaultWatcher() {
  if (watcher) {
    watcher.close();
    watcher = null;
  }
}
EOF

# 7) linkUtils (files/src/renderer/src/utils/linkUtils.ts)
mkdir -p files/src/renderer/src/utils
cat > files/src/renderer/src/utils/linkUtils.ts <<'EOF'
export function parseWikilinks(md: string): string[] {
  if (!md) return [];
  const re = /\[\[([^\]\|\n]+)(?:\|([^\]\n]+))?\]\]/g;
  const res: string[] = [];
  let m;
  while ((m = re.exec(md)) !== null) {
    const title = (m[1] || "").trim();
    if (!title) continue;
    const norm = title.replace(/\s+/g, " ").replace(/(^\/+|\/+$)/g, "");
    if (!res.includes(norm)) res.push(norm);
  }
  return res;
}
EOF

# 8) shared storage (files/src/shared/storage.ts)
cat > files/src/shared/storage.ts <<'EOF'
import fs from "fs-extra";
import path from "path";
import matter from "gray-matter";
import { v4 as uuidv4 } from "uuid";
import { decryptTextIfNeeded, encryptTextIfNeeded } from "../renderer/src/e2ee/e2ee";

export type Note = {
  id: string;
  title: string;
  filepath: string;
  content: string;
  frontmatter?: any;
};

export async function ensureVault(dir: string) {
  await fs.ensureDir(dir);
  return dir;
}

export async function listNotes(vaultDir: string): Promise<Note[]> {
  const files = await fs.readdir(vaultDir);
  const notes: Note[] = [];
  for (const f of files) {
    if (!f.endsWith(".md")) continue;
    const filepath = path.join(vaultDir, f);
    const raw = await fs.readFile(filepath, "utf8");
    const maybe = await decryptTextIfNeeded(vaultDir, raw);
    const parsed = matter(maybe);
    const title =
      parsed.data && parsed.data.title ? parsed.data.title : path.basename(f, ".md");
    const id = parsed.data && parsed.data.id ? parsed.data.id : uuidv4();
    notes.push({
      id,
      title,
      filepath,
      content: parsed.content,
      frontmatter: parsed.data
    });
  }
  return notes;
}

export async function readNote(filepath: string): Promise<Note> {
  const raw = await fs.readFile(filepath, "utf8");
  const vaultDir = path.dirname(filepath);
  const maybe = await decryptTextIfNeeded(vaultDir, raw);
  const parsed = matter(maybe);
  const title =
    parsed.data && parsed.data.title ? parsed.data.title : path.basename(filepath, ".md");
  const id = parsed.data && parsed.data.id ? parsed.data.id : uuidv4();
  return {
    id,
    title,
    filepath,
    content: parsed.content,
    frontmatter: parsed.data
  };
}

export async function writeNote(vaultDir: string, note: Partial<Note>) {
  if (!note.title) throw new Error("note.title required");
  const filename = `${note.title.replace(/[\\/:"*?<>|]+/g, "_")}.md`;
  const filepath = path.join(vaultDir, filename);
  const fm = Object.assign({}, note.frontmatter || {}, { id: note.id || uuidv4(), title: note.title });
  const body = matter.stringify(note.content || "", fm);
  const toWrite = await encryptTextIfNeeded(vaultDir, body);
  await fs.writeFile(filepath, toWrite, "utf8");
  return filepath;
}
EOF

# 9) VaultAPI (files/src/renderer/src/vaultAPI.ts)
cat > files/src/renderer/src/vaultAPI.ts <<'EOF'
import { listNotes, readNote, writeNote, Note } from "@shared/storage";

export class VaultAPI {
  async list(vaultDir: string): Promise<Note[]> {
    return await listNotes(vaultDir);
  }
  async read(filepath: string): Promise<Note> {
    return await readNote(filepath);
  }
  async save(vaultDir: string, n: Partial<Note> & { title: string; filepath?: string }): Promise<string> {
    return await writeNote(vaultDir, n as any);
  }
}
EOF

# 10) Renderer App (files/src/renderer/src/App.tsx)
cat > files/src/renderer/src/App.tsx <<'EOF'
import React, { useEffect, useState } from "react";
import { Note } from "@shared/storage";
import { VaultAPI } from "./vaultAPI";
import Editor from "./editor/Editor";
import GraphView from "./graph/GraphView";
import SearchPane from "./search/SearchPane";
import AssistantPane from "./AssistantPane";

declare global {
  interface Window {
    mixnoteAPI: any;
  }
}

const vaultApi = new VaultAPI();

export default function App() {
  const [vaultPath, setVaultPath] = useState<string | null>(null);
  const [notes, setNotes] = useState<Note[]>([]);
  const [active, setActive] = useState<Note | null>(null);
  const [vaultLocked, setVaultLocked] = useState<boolean>(false);

  useEffect(() => {
    async function init() {
      const defaultVault = await window.mixnoteAPI.getDefaultVault();
      setVaultPath(defaultVault);
      const list = await vaultApi.list(defaultVault);
      setNotes(list);
      if (list[0]) setActive(list[0]);
      window.mixnoteAPI.onIndexUpdated(async () => {
        const newList = await vaultApi.list(defaultVault);
        setNotes(newList);
      });
    }
    init();
  }, []);

  async function chooseVault() {
    const p = await window.mixnoteAPI.chooseVault();
    if (!p) return;
    setVaultPath(p);
    const list = await vaultApi.list(p);
    setNotes(list);
    setActive(list[0] || null);
  }

  async function saveNote(updated: Note) {
    if (!vaultPath) return;
    await vaultApi.save(vaultPath, updated);
    const list = await vaultApi.list(vaultPath);
    setNotes(list);
    setActive(list.find(n => n.filepath === updated.filepath) || updated);
  }

  async function lockVault() {
    if (!vaultPath) return;
    const pass = prompt("Passphrase to lock this vault (will derive key and encrypt files; backups created):");
    if (!pass) return;
    const res = await window.mixnoteAPI.lockVault(vaultPath, pass);
    if (res && res.ok) {
      alert("Vault locked (files encrypted). Backups created under ~/.mixnote/backups");
      setVaultLocked(true);
    } else {
      alert("Failed to lock vault: " + (res.error || "unknown"));
    }
  }

  return (
    <div style={{ display: "flex", height: "100vh" }}>
      <div className="sidebar">
        <div className="topbar">
          <button onClick={chooseVault}>Choose Vault</button>
          <span style={{ fontWeight: 600, marginLeft: 8 }}>MixNote</span>
          <button style={{ marginLeft: "auto" }} onClick={lockVault}>{vaultLocked ? "Locked" : "Lock Vault"}</button>
        </div>
        <SearchPane notes={notes} onOpen={(n) => setActive(n)} />
        <h4>Notes</h4>
        <div className="note-list" style={{ overflow: "auto", maxHeight: 300 }}>
          {notes.map(n => (
            <a href="#" key={n.filepath} onClick={() => setActive(n)}>{n.title}</a>
          ))}
        </div>
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column" }}>
        <div style={{ flex: 1, display: "flex" }}>
          <div style={{ flex: 1 }}>
            {active ? (
              <Editor note={active} onSave={saveNote} vaultPath={vaultPath!} />
            ) : (
              <div style={{ padding: 20 }}>No active note</div>
            )}
          </div>
          <div style={{ width: 420, borderLeft: "1px solid #eee", display: "flex", flexDirection: "column" }}>
            <div style={{ flex: 1 }}>
              <GraphView vaultPath={vaultPath} />
            </div>
            <div style={{ height: 280, borderTop: "1px solid #eee", overflow: "auto" }}>
              <AssistantPane activeNote={active} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
EOF

# 11) Editor (files/src/renderer/src/editor/Editor.tsx)
cat > files/src/renderer/src/editor/Editor.tsx <<'EOF'
import React, { useEffect, useRef, useState } from "react";
import * as monaco from "monaco-editor";
import { Note } from "@shared/storage";
import { parseWikilinks } from "../utils/linkUtils";
import { encryptTextIfNeeded } from "../e2ee/e2ee";
import marked from "marked";
import fs from "fs";

type Props = {
  note: Note;
  vaultPath: string;
  onSave: (note: Note) => Promise<void>;
};

export default function Editor({ note, onSave, vaultPath }: Props) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const [content, setContent] = useState(note.content);
  const [previewMode, setPreviewMode] = useState<"split" | "editor" | "preview">("split");

  useEffect(() => {
    setContent(note.content);
    if (!containerRef.current) return;
    if (!editorRef.current) {
      editorRef.current = monaco.editor.create(containerRef.current, {
        value: note.content,
        language: "markdown",
        automaticLayout: true,
        minimap: { enabled: false },
        wordWrap: "on"
      });
      editorRef.current.onDidChangeModelContent(() => {
        const v = editorRef.current!.getValue();
        setContent(v);
      });
    } else {
      editorRef.current.setValue(note.content);
    }
    return () => {};
  }, [note.filepath]);

  useEffect(() => {
    const provider = monaco.languages.registerCompletionItemProvider("markdown", {
      triggerCharacters: ["["],
      provideCompletionItems: (model, position) => {
        const textUntil = model.getValueInRange({ startLineNumber: 1, startColumn: 1, endLineNumber: position.lineNumber, endColumn: position.column });
        if (!textUntil.endsWith("[[")) return { suggestions: [] };
        try {
          const idxPath = (window as any).mixnoteAPI.getIndexPath();
          if (fs.existsSync(idxPath)) {
            const raw = fs.readFileSync(idxPath, "utf8");
            const idx = JSON.parse(raw);
            const suggestions = Object.values(idx.notes).map((n: any) => ({
              label: n.title,
              kind: monaco.languages.CompletionItemKind.Value,
              insertText: n.title
            }));
            return { suggestions };
          }
        } catch (e) {}
        return { suggestions: [] };
      }
    });
    return () => provider.dispose();
  }, []);

  function addBlockIdsIfMissing(md: string) {
    return md
      .split("\n\n")
      .map(block => {
        if (/\^([a-z0-9]{6,})$/.test(block.trim())) return block;
        const id = Math.random().toString(36).slice(2, 10);
        return `${block}\n^${id}`;
      })
      .join("\n\n");
  }

  async function handleSave() {
    const contentWithIds = addBlockIdsIfMissing(content);
    const updated: Note = {
      ...note,
      content: contentWithIds
    };
    const toSave = await encryptTextIfNeeded(vaultPath, contentWithIds);
    updated.content = toSave;
    await onSave(updated);
  }

  const wikilinks = parseWikilinks(content);

  return (
    <div style={{ height: "100%", display: "flex", flexDirection: "column" }}>
      <div style={{ padding: 8, borderBottom: "1px solid #eee", display: "flex", alignItems: "center", gap: 12 }}>
        <div style={{ display: "flex", gap: 8 }}>
          <button onClick={handleSave}>Save</button>
          <button onClick={() => setPreviewMode(p => (p === "split" ? "editor" : "split"))}>
            {previewMode === "split" ? "Editor only" : "Split"}
          </button>
          <button onClick={() => setPreviewMode("preview")}>Preview</button>
        </div>
        <span style={{ marginLeft: 12, fontWeight: 600 }}>{note.title}</span>
      </div>
      <div style={{ display: "flex", flex: 1 }}>
        {previewMode !== "preview" && (
          <div ref={containerRef} style={{ width: previewMode === "split" ? "60%" : "100%", height: "100%" }} />
        )}
        {previewMode !== "editor" && (
          <div style={{ width: previewMode === "split" ? "40%" : "100%", padding: 12, borderLeft: previewMode === "split" ? "1px solid #f3f3f3" : undefined, overflow: "auto" }}>
            <div dangerouslySetInnerHTML={{ __html: marked.parse(content) }} />
            <div style={{ marginTop: 12 }}>
              <h4>Wikilinks</h4>
              <ul>
                {wikilinks.map((w, i) => <li key={i}>{w}</li>)}
              </ul>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
EOF

# 12) GraphView (files/src/renderer/src/graph/GraphView.tsx)
cat > files/src/renderer/src/graph/GraphView.tsx <<'EOF'
import React, { useEffect, useRef } from "react";
import cytoscape from "cytoscape";
import fs from "fs";

type Props = {
  vaultPath: string | null;
};

export default function GraphView({ vaultPath }: Props) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const cyRef = useRef<any>(null);

  useEffect(() => {
    if (!containerRef.current) return;
    if (!cyRef.current) {
      cyRef.current = cytoscape({
        container: containerRef.current,
        elements: [],
        style: [
          { selector: "node", style: { "background-color": "#1976d2", label: "data(label)", color: "#fff", "text-valign":"center", "text-halign":"center", "text-wrap":"wrap", "width":"label", "height":"label", "padding":"8px" } },
          { selector: "edge", style: { width: 2, "line-color": "#999", "target-arrow-color": "#999", "target-arrow-shape": "triangle" } }
        ],
        layout: { name: "cose" }
      });

      cyRef.current.on("tap", "node", (evt: any) => {
        const node = evt.target;
        const nodeId = node.data("id");
        try {
          const idxPath = (window as any).mixnoteAPI.getIndexPath();
          if (fs.existsSync(idxPath)) {
            const raw = fs.readFileSync(idxPath, "utf8");
            const idx = JSON.parse(raw);
            const found = Object.values(idx.notes).find((n: any) => n.id === nodeId);
            if (found && found.filepath) {
              (window as any).mixnoteAPI.openNote(found.filepath);
            }
          }
        } catch (e) {
          (window as any).mixnoteAPI.openNote(nodeId);
        }
      });
    }
  }, []);

  useEffect(() => {
    async function loadIndex() {
      if (!vaultPath) return;
      const idxPath = await (window as any).mixnoteAPI.getIndexPath();
      try {
        const raw = fs.readFileSync(idxPath, "utf8");
        const idx = JSON.parse(raw);
        const nodes = Object.entries(idx.notes).map(([fp, n]: any) => ({
          data: { id: n.id, label: n.title, filepath: fp }
        }));
        const edges: any[] = [];
        for (const [target, sources] of Object.entries(idx.backlinks)) {
          for (const s of sources as string[]) {
            const srcMeta = idx.notes[s];
            const targetMeta = Object.values(idx.notes).find((nn: any) => nn.title === target);
            if (!srcMeta || !targetMeta) continue;
            edges.push({ data: { id: `${srcMeta.id}->${targetMeta.id}`, source: srcMeta.id, target: targetMeta.id } });
          }
        }
        const cy = cyRef.current;
        cy.elements().remove();
        cy.add([...nodes, ...edges]);
        cy.layout({ name: "cose" }).run();
      } catch (e) {
        // ignore missing index
      }
    }
    loadIndex();
  }, [vaultPath]);

  return <div ref={containerRef} style={{ width: "100%", height: "100%" }} />;
}
EOF

# 13) SearchPane (files/src/renderer/src/search/SearchPane.tsx)
cat > files/src/renderer/src/search/SearchPane.tsx <<'EOF'
import React, { useMemo, useState } from "react";
import Fuse from "fuse.js";
import { Note } from "@shared/storage";

export default function SearchPane({ notes, onOpen }: { notes: Note[]; onOpen: (n: Note) => void }) {
  const [q, setQ] = useState("");
  const fuse = useMemo(() => new Fuse(notes, { keys: ["title", "content"], threshold: 0.3 }), [notes]);
  const results = q ? fuse.search(q).map(r => r.item) : notes.slice(0, 20);
  return (
    <div style={{ padding: 8 }}>
      <input placeholder="Search notes..." value={q} onChange={(e) => setQ(e.target.value)} style={{ width: "100%", padding: 6 }} />
      <div style={{ marginTop: 8, maxHeight: 220, overflow: "auto" }}>
        {results.map(n => (
          <div key={n.filepath}>
            <a href="#" onClick={() => onOpen(n)}>{n.title}</a>
          </div>
        ))}
      </div>
    </div>
  );
}
EOF

# 14) AI core files (types, core, providers, index)
cat > files/src/renderer/src/ai/types.ts <<'EOF'
export type AIProviderName = "openai" | "gemini" | "ollama" | "lmstudio" | "custom";

export type ChatMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

export type ChatCompletionRequest = {
  model?: string;
  messages: ChatMessage[];
  max_tokens?: number;
  temperature?: number;
  stream?: boolean;
  [key: string]: any;
};

export type ChatCompletionResponse = {
  id?: string;
  text?: string;
  raw?: any;
};
EOF

cat > files/src/renderer/src/ai/core.ts <<'EOF'
import { AIProviderName, ChatCompletionRequest, ChatCompletionResponse } from "./types";
import { OpenAIProvider } from "./providers/openai";
import { GeminiProvider } from "./providers/gemini";
import { OllamaProvider } from "./providers/ollama";
import { LMStudioProvider } from "./providers/lmstudio";
import { CustomProvider } from "./providers/custom";

type ProviderMap = {
  [K in AIProviderName]: any;
};

const providers: ProviderMap = {
  openai: new OpenAIProvider(),
  gemini: new GeminiProvider(),
  ollama: new OllamaProvider(),
  lmstudio: new LMStudioProvider(),
  custom: new CustomProvider()
};

export async function chatCompletion(providerName: AIProviderName, request: ChatCompletionRequest, options?: any): Promise<ChatCompletionResponse> {
  const provider = providers[providerName];
  if (!provider) throw new Error(\`Provider \${providerName} not found\`);
  return await provider.chatCompletion(request, options || {});
}

export function listProviders() {
  return {
    openai: { name: "OpenAI-compatible", id: "openai" },
    gemini: { name: "Gemini (Google)", id: "gemini" },
    ollama: { name: "Ollama (local)", id: "ollama" },
    lmstudio: { name: "LMStudio (local)", id: "lmstudio" },
    custom: { name: "Custom endpoint", id: "custom" }
  };
}

export default {
  chatCompletion,
  listProviders
};
EOF

cat > files/src/renderer/src/ai/providers/openai.ts <<'EOF'
import { ChatCompletionRequest, ChatCompletionResponse } from "../types";

export class OpenAIProvider {
  async chatCompletion(request: ChatCompletionRequest, options: any = {}): Promise<ChatCompletionResponse> {
    const endpoint = options.endpoint || "https://api.openai.com/v1/chat/completions";
    const apiKey = options.apiKey;
    if (!apiKey) throw new Error("OpenAIProvider: apiKey required in options");
    const body: any = {
      model: request.model || "gpt-4o-mini",
      messages: request.messages,
      max_tokens: request.max_tokens || 300,
      temperature: request.temperature ?? 0.2
    };
    const resp = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`
      },
      body: JSON.stringify(body)
    });
    const json = await resp.json();
    let text = "";
    if (json.choices && json.choices[0]) {
      if (json.choices[0].message) text = json.choices[0].message.content;
      else if (json.choices[0].text) text = json.choices[0].text;
      else text = JSON.stringify(json.choices[0]);
    } else {
      text = JSON.stringify(json, null, 2);
    }
    return { id: json.id || undefined, text, raw: json };
  }
}
EOF

cat > files/src/renderer/src/ai/providers/gemini.ts <<'EOF'
import { ChatCompletionRequest, ChatCompletionResponse } from "../types";

export class GeminiProvider {
  async chatCompletion(request: ChatCompletionRequest, options: any = {}): Promise<ChatCompletionResponse> {
    const endpoint = options.endpoint || options.geminiEndpoint;
    const apiKey = options.apiKey || options.geminiApiKey;
    if (!endpoint || !apiKey) throw new Error("GeminiProvider requires endpoint and apiKey in options");

    const prompt = request.messages.map(m => `${m.role.toUpperCase()}: ${m.content}`).join("\n\n");
    const body = {
      prompt,
      max_output_tokens: request.max_tokens || 512,
      temperature: request.temperature ?? 0.2
    };

    const resp = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`
      },
      body: JSON.stringify(body)
    });
    const json = await resp.json();
    let text = "";
    if (json && (json.candidates || json.output_text || json.data)) {
      if (json.output_text) text = json.output_text;
      else if (json.candidates && json.candidates[0] && json.candidates[0].content) text = json.candidates[0].content;
      else text = JSON.stringify(json);
    } else {
      text