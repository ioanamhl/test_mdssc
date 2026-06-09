# mdssc-pipeline-template

# MDSSC Pipeline Template

> Integrează **OPSWAT MetaDefender Software Supply Chain (MDSSC)** în orice proiect în mai puțin de 30 de minute.

[![CI/CD](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-2088FF?logo=github-actions&logoColor=white)](https://github.com/features/actions)
[![Jenkins](https://img.shields.io/badge/Jenkins-required-D24939?logo=jenkins&logoColor=white)](https://www.jenkins.io)
[![MDSSC](https://img.shields.io/badge/OPSWAT-MDSSC-00A651)](https://www.opswat.com/products/metadefender/software-supply-chain)

---

## Ce face acest template

La fiecare push pe `main`, pipeline-ul:

1. **Scanează codul** cu MDSSC — detectează secrete commitate, vulnerabilități în dependențe, malware, generează SBOM
2. **Blochează deploy-ul** dacă scanarea găsește probleme la sau peste pragul configurat
3. **Buildează aplicația** — adaptat automat la stack-ul tău (Node.js, Python, Java, Go)
4. **Scanează artefactele** — bundle frontend, arhivă backend, imagini Docker
5. **Deploiează** pe serverul tău via PM2, Docker, sau systemd
6. **Rulează teste E2E** cu Playwright pe aplicația tocmai deploiată
7. **Creează un GitHub Release** automat cu versiune semver calculată din mesajul commit-ului

---

## Structura template-ului

```
mdssc-pipeline-template/
├── pipeline.config.yml        ← singurul fișier pe care îl completezi
├── setup-jenkins.sh           ← instalare automată Jenkins (obligatoriu)
├── .github/
│   └── workflows/
│       └── cicd.yml           ← GitHub Actions orchestrator
├── ci/
│   ├── Jenkinsfile            ← pipeline Jenkins parametrizat
│   └── mdsscAdvanced.groovy   ← librărie MDSSC API wrapper
└── README.md
```

---

## Arhitectura pipeline-ului

```
PUSH ──> GITHUB ACTIONS
              │
              ├── read-config     → citește pipeline.config.yml
              │
              ├── mdssc-scan      → OPSWAT MDSSC (rulează mereu)
              │        │
              │    [MDSSC PASS]
              │        │
              ├── deploy ─────────────────────> JENKINS (obligatoriu)
              │                                      │── MDSSC source scan (indirect, din Git)
              │                                      │── Build
              │                                      │── MDSSC artifact scan
              │                                      └── Deploy pe VPS
              ├── e2e             → Playwright pe aplicația deploiată
              │
              └── release         → GitHub Release automat (semver)
```

---

## Setup în 4 pași

### Pasul 1 — Copiază fișierele în repo-ul tău

```bash
cp pipeline.config.yml         your-project/
cp .github/workflows/cicd.yml  your-project/.github/workflows/
cp -r ci/                      your-project/
```

### Pasul 2 — Completează `pipeline.config.yml`

Acesta este singurul fișier pe care trebuie să îl modifici:

```yaml
# Identificare proiect
project_name: "my-app"
github_repo: "https://github.com/your-org/your-repo"

# Stack aplicație
stack: "node" # node | python | java | go
build_command: "npm run build"
build_output: "dist/"
app_port: 3000

# Jenkins — obligatoriu
jenkins_mode: "docker" # docker | external
jenkins_url: "http://IP-VPS:8080" # adresa Jenkins-ului tău
jenkins_job: "my-pipeline"

# Deploy
deploy_method: "pm2" # pm2 | docker | systemd | none

# MDSSC
mdssc_threshold: "critical" # critical | high | medium | low
mdssc_scan_type: "both" # indirect | artifacts | both
```

### Pasul 3 — Adaugă secretele în GitHub

Mergi la repo → **Settings → Secrets and variables → Actions**:

| Secret               | Descriere                    | Obligatoriu |
| -------------------- | ---------------------------- | ----------- |
| `MDSSC_SERVER`       | URL-ul serverului MDSSC      | ✅ Da       |
| `MDSSC_API_KEY`      | API key-ul MDSSC             | ✅ Da       |
| `VPS_BASE_URL`       | URL-ul aplicației pentru E2E | ✅ Da       |
| `JENKINS_VPS_URL`    | URL-ul Jenkins               | ✅ Da       |
| `JENKINS_USER`       | Username Jenkins             | ✅ Da       |
| `JENKINS_API_TOKEN`  | Token Jenkins                | ✅ Da       |
| `DOCKERHUB_USERNAME` | Docker Hub username          | ❌ Opțional |
| `DOCKERHUB_TOKEN`    | Docker Hub token             | ❌ Opțional |

### Pasul 4 — Fă un push

```bash
git add pipeline.config.yml .github/workflows/cicd.yml ci/
git commit -m "feat: add MDSSC pipeline"
git push origin main
```

Mergi la **Actions** pe GitHub. La primul run reușit se creează automat un GitHub Release.

---

## Modurile Jenkins

Jenkins este **obligatoriu** — build-ul, scanarea artefactelor și deploy-ul rulează întotdeauna prin Jenkins. Alegi doar **unde** rulează Jenkins:

### `jenkins_mode: "docker"` — Jenkins local via Docker

Potrivit pentru demo și development. Jenkins pornește într-un container pe mașina ta.

```yaml
jenkins_mode: "docker"
jenkins_url: "http://IP-VPS:8080" # IP-ul serverului cu Docker
jenkins_job: "my-pipeline"
```

Pornești Jenkins automat cu scriptul inclus:

```bash
chmod +x setup-jenkins.sh
./setup-jenkins.sh
```

> ⚠️ Dacă rulezi Docker pe laptop (`localhost`), GitHub Actions nu poate triggeriza Jenkins.
> Ai două opțiuni:
>
> - Rulează Docker pe un **VPS cu IP public** — soluție recomandată
> - Folosește un tunel [ngrok](https://ngrok.com) temporar pe laptop:
>   ```bash
>   ngrok http 8080
>   # pune URL-ul ngrok în jenkins_url din config
>   ```

---

### `jenkins_mode: "external"` — Jenkins pe VPS propriu

Ai deja Jenkins instalat pe un server. Template-ul triggerizează automat job-ul din GitHub Actions.

```yaml
jenkins_mode: "external"
jenkins_url: "http://IP-VPS:8080" # sau domeniu: https://jenkins.firma.com
jenkins_job: "my-pipeline"
```

Configurare Jenkins necesară:

1. Creează un job Pipeline în Jenkins
2. Setează Script Path: `ci/Jenkinsfile`
3. Adaugă credențialele MDSSC:
   - Manage Jenkins → Credentials → Add → Secret text
   - ID: `mdssc-api-key`, Value: API key-ul MDSSC

---

## Instalare Jenkins

Jenkins trebuie să ruleze pe un server cu IP public accesibil din GitHub Actions. Folosește scriptul inclus pentru instalare automată:

```bash
chmod +x setup-jenkins.sh
./setup-jenkins.sh
```

Scriptul detectează automat mediul și alege metoda de instalare:

- **Docker disponibil** → pornește Jenkins în container
- **Ubuntu/Debian fără Docker** → instalare nativă via `apt`
- **Alt OS** → instrucțiuni pentru pașii următori

Cerințe: `curl`, `git`, și opțional `yq`:

```bash
wget -qO /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
chmod +x /usr/local/bin/yq
```

---

## Stack-uri suportate

| Stack   | `stack:` | Build automat                     |
| ------- | -------- | --------------------------------- |
| Node.js | `node`   | `npm ci` + comanda ta             |
| Python  | `python` | `pip install -r requirements.txt` |
| Java    | `java`   | `mvn package -DskipTests`         |
| Go      | `go`     | `go build ./...`                  |
| Custom  | orice    | exact `build_command` din config  |

---

## Tipuri de scanare MDSSC

| `mdssc_scan_type` | Ce face                                                                         |
| ----------------- | ------------------------------------------------------------------------------- |
| `indirect`        | MDSSC citește direct din Git prin referință de branch — scanare cod sursă       |
| `artifacts`       | Scanează artefactele de build — bundle frontend, arhivă backend, imagini Docker |
| `both`            | Ambele — recomandat                                                             |

---

## Versioning automat (semver)

| Mesaj commit                       | Bump      | Exemplu         |
| ---------------------------------- | --------- | --------------- |
| Conține `BREAKING CHANGE` sau `!:` | **Major** | v1.0.0 → v2.0.0 |
| Începe cu `feat`                   | **Minor** | v1.0.0 → v1.1.0 |
| Orice altceva                      | **Patch** | v1.0.0 → v1.0.1 |

```bash
git commit -m "feat: add authentication"      # → minor bump
git commit -m "fix: resolve login bug"        # → patch bump
git commit -m "feat!: redesign API BREAKING CHANGE" # → major bump
```

---

## Pragul de vulnerabilitate

```yaml
mdssc_threshold: "critical"  # blochează doar la vulnerabilități critice
mdssc_threshold: "high"      # blochează la high + critical
mdssc_threshold: "medium"    # blochează la medium + high + critical
mdssc_threshold: "low"       # blochează la orice vulnerabilitate
```

---

## Troubleshooting

**MDSSC scan eșuează cu "connection refused"**
Verifică că `MDSSC_SERVER` e accesibil din GitHub Actions — trebuie să fie un IP/domeniu public, nu `localhost`.

**Jenkins trigger eșuează cu HTTP 403**
Verifică `JENKINS_USER` și `JENKINS_API_TOKEN`. Asigură-te că CSRF protection e configurat corect în Jenkins (Manage Jenkins → Configure Global Security).

**E2E tests eșuează**
Verifică `VPS_BASE_URL` — trebuie să fie URL-ul aplicației deploiată, accesibil public. Asigură-te că jobul `deploy` a trecut înainte.

**Release nu se creează**
Jobul `release` rulează doar pe push pe `main`, după ce `e2e` a trecut. Verifică că `GITHUB_TOKEN` are permisiuni `contents: write`.

**MDSSC detectează secrete în cod**
Scoate secretele din istoricul Git cu BFG Repo Cleaner și rotește toate cheile compromise:

```bash
java -jar bfg.jar --delete-files .env
git reflog expire --expire=now --all
git gc --prune=now --aggressive
git push --force
```

---

## Demo

[mdssc_project](https://github.com/ioanamhl/mdssc_project) este un demo complet care folosește acest template pe o aplicație reală (GreenCart — magazin online Node.js + React), demonstrând scanare MDSSC sursă + artefacte, pipeline Jenkins cu 6 stage-uri, și release-uri automate.

---

_Construit pentru demonstrarea integrării OPSWAT MDSSC în CI/CD pipelines._
