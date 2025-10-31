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
    mainWindow.webContents.openDevTools();
  } else {
    // in production, renderer built output is under resources/app.asar or unpacked path
    const indexPath = path.join(app.getAppPath(), "files/src/renderer/dist/index.html");
    mainWindow.loadFile(indexPath).catch(() => {
      // fallback to relative path
      mainWindow!.loadFile(path.join(__dirname, "../renderer/index.html"));
    });
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

// Google OAuth installed-app scaffold: open consent page
ipcMain.handle("start-google-oauth", async (_ev, clientId: string, scope: string) => {
  const redirectUri = "urn:ietf:wg:oauth:2.0:oob";
  const authUrl = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(clientId)}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&scope=${encodeURIComponent(scope)}&access_type=offline&prompt=consent`;
  await open(authUrl);
  return { ok: true, message: "Opened browser for consent. Paste returned code into the app to exchange." };
});

app.on("before-quit", () => {
  stopVaultWatcher();
});