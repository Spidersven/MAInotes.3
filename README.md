```markdown
# MixNote — Local-first Obsidian-like notes with AI & Sync

Dieser Branch/Feature-Set liefert viele Verbesserungen:

Hauptfeatures
- Editor: Monaco-basiert, Split-Preview, Block-IDs, Wikilink-Autocomplete.
- Indexer: persistente .mixnote/index.json, Filepath/ID gespeichert, IPC-Update Events.
- Graph: Cytoscape-Graph, klickbare Nodes öffnen Notizen.
- E2EE: libsodium Schlüsselableitung + AES-like secretbox, Keys in OS secure store via keytar, Backups unter ~/.mixnote/backups.
- Assistant: AI-Summarize/Generate (OpenAI/Gemini kompatibel), Key-Paste UI (für Demo).
- Google Drive: OAuth scaffold (installed app) + token-exchange helper (scaffold).
- Packaging: electron-builder config.
- CI: einfacher Build-Workflow.

Sicherheit & Setup
1. Backup deines Vaults, bevor du Lock/Encrypt ausführst.
2. Für Google Drive: registriere Desktop-App in Google Cloud und füge client_id/secret hinzu.
3. Für AI: API-Key im Assistant einfügen; in Produktion: keytar / Backend.

Entwicklung / Start
- Root:
  npm install
  npm run start

Packaging
- npm run build
- npm run pack-electron

Hinweis: native module (keytar) können native Rebuild-Schritte benötigen (electron-rebuild) beim Packaging.
```