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