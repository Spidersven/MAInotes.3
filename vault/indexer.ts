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
  db.exec(`
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
  `);
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