# Ghid de utilizare — MDSSC Pipeline Template

Acest ghid explică pas cu pas cum să integrezi template-ul într-un proiect nou, de la zero până la primul pipeline funcțional.

---

## Cerințe prealabile

Înainte de a începe, asigură-te că ai instalate:

| Tool | Verificare | Instalare |
|------|-----------|-----------|
| Docker | `docker --version` | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Git | `git --version` | preinstalat pe majoritatea sistemelor |
| cloudflared | `cloudflared version` | `winget install Cloudflare.cloudflared` (Windows) |
| Node.js 20+ | `node --version` | [nodejs.org](https://nodejs.org) — doar pentru stack Node |

Ai nevoie și de:
- Un **cont GitHub** cu un repo în care vei integra pipeline-ul
- Un **server MDSSC** cu URL și API key (furnizat de OPSWAT)

---

## Pasul 1 — Copiază fișierele în proiectul tău

Din folderul `mdssc-pipeline-template/`, copiază fișierele în rădăcina proiectului tău:

```bash
# Fișierul de configurare
cp pipeline.config.yml  your-project/

# GitHub Actions workflow
mkdir -p your-project/.github/workflows
cp .github/workflows/cicd.yml  your-project/.github/workflows/

# Jenkinsfile și librăria MDSSC
mkdir -p your-project/ci
cp ci/Jenkinsfile           your-project/ci/
cp ci/mdsscAdvanced.groovy  your-project/ci/
```

Structura finală în proiectul tău:

```
your-project/
├── pipeline.config.yml
├── .github/
│   └── workflows/
│       └── cicd.yml
└── ci/
    ├── Jenkinsfile
    └── mdsscAdvanced.groovy
```

---

## Pasul 2 — Completează `pipeline.config.yml`

Deschide `pipeline.config.yml` și completează valorile pentru proiectul tău:

```yaml
project_name: "my-app"                             # numele proiectului
github_repo: "https://github.com/user/my-app"      # URL-ul repo-ului tău

stack: "node"               # node | python | java | go
build_command: "npm run build"
build_output: "dist/"       # folderul generat de build (dist/, build/, target/, etc.)
app_port: 3000              # portul pe care rulează aplicația ta

jenkins_mode: "docker"      # docker = Jenkins local via Docker
jenkins_url: ""             # completezi la Pasul 4, după ce pornești tunelul
jenkins_port: 8080
jenkins_job: "my-app-pipeline"

deploy_method: "pm2"        # pm2 | docker | systemd | none

mdssc_threshold: "none"     # none = raportează fără să blocheze | critical | high | medium | low
```

> **Notă `build_output`:** Create React App generează în `build/`, Vite în `dist/`, Maven în `target/`. Verifică proiectul tău.

---

## Pasul 3 — Instalează și pornește Jenkins

Rulează scriptul de setup din folderul `mdssc-pipeline-template/`:

```bash
chmod +x setup-jenkins.sh
./setup-jenkins.sh
```

Scriptul face automat:
- Pornește Jenkins într-un container Docker (JDK 21)
- Instalează plugin-urile necesare
- Instalează Node.js 20 și PM2 în container
- Creează utilizatorul `admin` cu o parolă generată aleatoriu
- Generează un API token pentru Jenkins
- Creează job-ul pipeline configurat din `pipeline.config.yml`

La final, scriptul afișează:

```
==========================================
  Jenkins pornit cu succes!
==========================================
  URL:           http://localhost:8080
  User:          admin
  Parolă:        AbCdEfGh12345678
  API Token:     1234abcd5678efgh...

  Adaugă direct ca secret GitHub: JENKINS_API_TOKEN
==========================================
```

**Salvează parola și token-ul** — vei avea nevoie de ele la Pasul 5.

---

## Pasul 4 — Creează tuneluri pentru acces extern

GitHub Actions rulează în cloud și nu poate accesa `localhost`. Ai nevoie de tuneluri pentru:
- **Jenkins** (port 8080) — pentru ca GitHub Actions să poată triggeriza build-ul
- **Aplicația ta** (portul din `app_port`) — pentru testele E2E

Deschide **două terminale separate** și rulează:

**Terminal 1 — Tunel Jenkins:**
```bash
cloudflared tunnel --url http://localhost:8080
```

**Terminal 2 — Tunel aplicație:**
```bash
cloudflared tunnel --url http://localhost:3000  # înlocuiește cu portul tău
```

Fiecare terminal afișează un URL de forma:
```
https://random-words.trycloudflare.com
```

> **Important:** Lasă ambele terminale deschise pe toată durata rulării pipeline-ului. La oprire, URL-urile se schimbă — va trebui să actualizezi secretele GitHub.

**Actualizează `pipeline.config.yml`** cu URL-ul Jenkins:
```yaml
jenkins_url: "https://random-words.trycloudflare.com"  # URL-ul din Terminal 1
```

---

## Pasul 5 — Adaugă secretele în GitHub

Mergi la repo-ul tău pe GitHub → **Settings → Secrets and variables → Actions → New repository secret**:

| Nume secret | Valoare | Unde o găsești |
|------------|---------|----------------|
| `MDSSC_SERVER` | URL-ul serverului MDSSC | Furnizat de OPSWAT |
| `MDSSC_API_KEY` | API key-ul MDSSC | Furnizat de OPSWAT |
| `JENKINS_VPS_URL` | URL-ul tunelului Jenkins | Terminal 1 (Pasul 4) |
| `JENKINS_USER` | `admin` | Afișat de setup-jenkins.sh |
| `JENKINS_API_TOKEN` | Token-ul Jenkins | Afișat de setup-jenkins.sh |
| `VPS_BASE_URL` | URL-ul tunelului aplicației | Terminal 2 (Pasul 4) |

---

## Pasul 6 — Configurează URL-ul Jenkins în interfața Jenkins

Accesează Jenkins la URL-ul din tunelul tău și configurează adresa externă:

1. Mergi la `https://[url-tunel-jenkins]/manage/configure`
2. Câmpul **Jenkins URL** → pune URL-ul tunelului Jenkins (ex: `https://random-words.trycloudflare.com`)
3. Click **Save**

> Fără acest pas, Jenkins generează linkuri interne (`localhost:8080`) care nu sunt accesibile din GitHub Actions.

---

## Pasul 7 — Asigură-te că ai `package-lock.json` (doar pentru stack Node)

Jenkins folosește `npm ci` care necesită fișierul `package-lock.json`. Dacă nu îl ai:

```bash
# În folderul backend:
cd backend && npm install

# În folderul frontend:
cd frontend && npm install
```

Verifică că `package-lock.json` **nu este în `.gitignore`** și adaugă-l în git:

```bash
git add backend/package-lock.json frontend/package-lock.json
git commit -m "chore: add package-lock.json"
```

---

## Pasul 8 — Fă push și urmărește pipeline-ul

```bash
git add .
git commit -m "feat: add MDSSC pipeline integration"
git push origin main
```

Mergi pe GitHub → tab **Actions** și urmărește rularea. Pipeline-ul parcurge:

```
GitHub Actions:
  ✅ Read pipeline.config.yml
  ✅ MDSSC Scan (cod sursă — Docker)
  ✅ Deploy → trigherizează Jenkins
       Jenkins:
         ✅ Checkout
         ✅ Check Health (MDSSC server)
         ✅ Fetch Workflow
         ✅ Security Scan (npm audit + ESLint)
         ✅ MDSSC Source Code Scan
         ✅ Build
         ✅ Artifact Scan
         ✅ Deploy (PM2 / Docker / systemd)
  ✅ E2E Tests (Playwright)
  ✅ GitHub Release (semver automat)
```

---

## Ce se întâmplă la fiecare push

| Ramură | Ce rulează |
|--------|-----------|
| Orice ramură | MDSSC scan cod sursă |
| `main` (push direct) | Tot pipeline-ul complet + release automat |
| `main` (pull request) | MDSSC scan + build, fără deploy și release |

---

## Versioning automat

Release-urile se creează automat după mesajul commit-ului:

| Mesaj commit | Tip bump | Exemplu |
|-------------|---------|---------|
| `feat: ...` | minor | v1.0.0 → v1.1.0 |
| `fix: ...`, `chore: ...`, orice altceva | patch | v1.0.0 → v1.0.1 |
| `feat!: ...` sau conține `BREAKING CHANGE` | major | v1.0.0 → v2.0.0 |

---

## Oprire și repornire

Dacă oprești și repornești Jenkins sau tunelurile, trebuie să:

1. Repornești tunelurile (`cloudflared tunnel --url ...`) — URL-urile se schimbă
2. Actualizezi secretele GitHub (`JENKINS_VPS_URL` și `VPS_BASE_URL`) cu noile URL-uri
3. Actualizezi `jenkins_url` în `pipeline.config.yml` și dai push

> **Sfat:** Dacă dorești URL-uri stabile, creează un cont Cloudflare gratuit și configurează un **Named Tunnel** cu domeniu fix.

---

## Depanare rapidă

**Jenkins nu pornește**
```bash
docker logs jenkins-[project-name]
```

**MDSSC scan eșuează cu "connection refused"**
Verifică că `MDSSC_SERVER` e accesibil din internet (nu `localhost`).

**Jenkins trigger HTTP 400/403**
- 400: Verifică că `JENKINS_API_TOKEN` e corect și nu a expirat
- 403: Regenerează token-ul din Jenkins UI → User → Configure → API Token

**Build eșuează cu `npm ci` error**
Lipsește `package-lock.json` — vezi Pasul 7.

**E2E tests eșuează**
Verifică că `VPS_BASE_URL` e accesibil public și că deploy-ul a trecut cu succes în Jenkins.

**Release nu se creează**
Jobul `release` rulează doar după ce E2E trece pe branch `main`. Verifică permisiunile `GITHUB_TOKEN` (`contents: write`).
