#!/usr/bin/env bash
# =============================================================================
#  MDSSC Pipeline Template — setup-jenkins.sh
#
#  Instalare automată Jenkins pentru integrarea MDSSC.
#  Detectează automat mediul și alege metoda de instalare:
#    - Docker disponibil  → Jenkins în container
#    - Ubuntu/Debian      → instalare nativă via apt
#
#  Utilizare:
#    chmod +x setup-jenkins.sh
#    ./setup-jenkins.sh
# =============================================================================

set -euo pipefail

# ── Culori ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

# ── Header ───────────────────────────────────────────────────────────────────
header() {
  echo ""
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo -e "${BOLD}${CYAN}   MDSSC Pipeline Template — Jenkins Setup${NC}"
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo ""
}

# ── Citire pipeline.config.yml ────────────────────────────────────────────────
read_config() {
  local key="$1"
  local default="${2:-}"
  if [ ! -f "pipeline.config.yml" ]; then echo "$default"; return; fi

  if command -v yq &>/dev/null; then
    local val
    val=$(yq ".${key}" pipeline.config.yml 2>/dev/null || echo "")
    if [ -z "$val" ] || [ "$val" = "null" ]; then echo "$default"; else echo "$val"; fi
  else
    # fallback: grep simplu pentru valori scalare (fără yq)
    local val
    val=$(grep -E "^${key}:" pipeline.config.yml 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr -d "'")
    if [ -z "$val" ] || [ "$val" = "null" ]; then echo "$default"; else echo "$val"; fi
  fi
}

# ── Plugin-uri necesare pentru MDSSC ─────────────────────────────────────────
JENKINS_PLUGINS=(
  "git"
  "workflow-aggregator"
  "pipeline-stage-view"
  "credentials-binding"
  "plain-credentials"
  "docker-workflow"
  "timestamper"
  "ws-cleanup"
  "ansicolor"
  "github"
  "github-branch-source"
  "nodejs"
  "pipeline-utility-steps"
)

# ── Verificare dependențe ─────────────────────────────────────────────────────
check_deps() {
  log_step "Verificare dependențe"
  local MISSING=()
  command -v curl &>/dev/null || MISSING+=("curl")
  command -v git  &>/dev/null || MISSING+=("git")

  if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Lipsesc: ${MISSING[*]}"
    log_error "Instalează-le și rulează scriptul din nou."
    exit 1
  fi

  if ! command -v yq &>/dev/null; then
    log_warn "yq nu e instalat — se folosesc valori default."
    log_warn "Pentru citire automată din pipeline.config.yml, instalează yq:"
    log_warn "  wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    log_warn "  chmod +x /usr/local/bin/yq"
  fi

  log_ok "Dependențe OK"
}

# ── Detectare mod instalare ───────────────────────────────────────────────────
detect_mode() {
  log_step "Detectare mediu de instalare"

  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
    log_ok "Docker detectat ($(docker --version | cut -d' ' -f3 | tr -d ','))"
  else
    DOCKER_AVAILABLE=false
    log_info "Docker nu e disponibil"
  fi

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    log_ok "OS detectat: ${PRETTY_NAME:-$ID}"
  else
    OS_ID="unknown"
  fi

  JENKINS_MODE=$(read_config "jenkins_mode" "docker")

  if [ "$DOCKER_AVAILABLE" = true ] || [ "$JENKINS_MODE" = "docker" ]; then
    INSTALL_MODE="docker"
    log_ok "Mod selectat: ${BOLD}Docker${NC}"
  elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    INSTALL_MODE="linux"
    log_ok "Mod selectat: ${BOLD}Linux nativ (apt)${NC}"
  else
    log_error "Docker nu e disponibil și OS-ul ($OS_ID) nu e suportat pentru instalare nativă."
    log_error "Instalează Docker și rulează scriptul din nou."
    exit 1
  fi
}

# ── Așteptare Jenkins ready ───────────────────────────────────────────────────
wait_for_jenkins() {
  local PORT="$1"
  local MAX_WAIT=120
  local WAITED=0

  log_info "Aștept Jenkins să pornească (max ${MAX_WAIT}s)..."
  while ! curl -sf "http://localhost:${PORT}/login" > /dev/null 2>&1; do
    sleep 3
    WAITED=$((WAITED + 3))
    echo -ne "  ${CYAN}⏳ ${WAITED}s...${NC}\r"
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
      echo ""
      log_error "Jenkins nu a pornit în ${MAX_WAIT}s."
      log_error "Verifică logs: docker logs jenkins-${PROJECT_NAME}"
      exit 1
    fi
  done
  echo ""
  log_ok "Jenkins este online!"
}

# ── Configurare securitate Jenkins ───────────────────────────────────────────
setup_jenkins_security() {
  local PORT="$1"
  local CREDENTIALS_FILE="$2"

  log_step "Configurare securitate Jenkins (creare user admin + API token)"

  # Generează parolă aleatoare
  local ADMIN_PASS
  ADMIN_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16) || \
    ADMIN_PASS="Admin$(date +%H%M%S)"

  # Script Groovy: creare user admin + activare security
  local groovy_script="
import jenkins.model.*
import hudson.security.*
def instance = Jenkins.getInstance()
if (!(instance.getSecurityRealm() instanceof HudsonPrivateSecurityRealm)) {
  def realm = new HudsonPrivateSecurityRealm(false)
  realm.createAccount('admin', '${ADMIN_PASS}')
  instance.setSecurityRealm(realm)
  def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
  strategy.setAllowAnonymousRead(false)
  instance.setAuthorizationStrategy(strategy)
  instance.save()
  println 'Security configured successfully'
} else {
  println 'Security already configured'
}
"

  # CSRF crumb fără autentificare (Jenkins e încă nesecurizat)
  local cookie_jar="/tmp/jenkins-sec-$$.txt"
  local crumb_json CRUMB_VALUE CRUMB_FIELD
  crumb_json=$(curl -sf --cookie-jar "$cookie_jar" \
    "http://localhost:${PORT}/crumbIssuer/api/json" 2>/dev/null || echo "")
  CRUMB_VALUE=$(echo "$crumb_json" | grep -o '"crumb":"[^"]*"'             | sed 's/"crumb":"//;s/"//')
  CRUMB_FIELD=$(echo "$crumb_json" | grep -o '"crumbRequestField":"[^"]*"' | sed 's/"crumbRequestField":"//;s/"//')
  CRUMB_FIELD="${CRUMB_FIELD:-Jenkins-Crumb}"

  # Rulează scriptul Groovy via Script Console
  local script_result
  script_result=$(curl -s --cookie "$cookie_jar" \
    -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
    -X POST "http://localhost:${PORT}/scriptText" \
    --data-urlencode "script=${groovy_script}" 2>/dev/null)

  if echo "$script_result" | grep -q "configured"; then
    log_ok "User 'admin' creat și securitatea activată"
  else
    log_warn "Security setup răspuns: ${script_result:-no response}"
  fi

  sleep 3

  # Generează API token cu admin autentificat
  crumb_json=$(curl -sf -u "admin:${ADMIN_PASS}" --cookie-jar "$cookie_jar" \
    "http://localhost:${PORT}/crumbIssuer/api/json" 2>/dev/null || echo "")
  CRUMB_VALUE=$(echo "$crumb_json" | grep -o '"crumb":"[^"]*"'             | sed 's/"crumb":"//;s/"//')
  CRUMB_FIELD=$(echo "$crumb_json" | grep -o '"crumbRequestField":"[^"]*"' | sed 's/"crumbRequestField":"//;s/"//')
  CRUMB_FIELD="${CRUMB_FIELD:-Jenkins-Crumb}"

  local token_response
  token_response=$(curl -s -u "admin:${ADMIN_PASS}" --cookie "$cookie_jar" \
    -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
    -X POST "http://localhost:${PORT}/user/admin/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" \
    --data "newTokenName=gh-actions-token" 2>/dev/null)

  local API_TOKEN
  API_TOKEN=$(echo "$token_response" | grep -o '"tokenValue":"[^"]*"' | sed 's/"tokenValue":"//;s/"//')

  rm -f "$cookie_jar"

  # Salvează credențialele în Jenkins home (volum persistent)
  {
    echo "JENKINS_USER=admin"
    echo "JENKINS_PASSWORD=${ADMIN_PASS}"
    echo "JENKINS_API_TOKEN=${API_TOKEN}"
  } > "$CREDENTIALS_FILE"

  log_ok "Credențiale salvate în: ${CREDENTIALS_FILE}"

  # Exportă pentru utilizare în restul scriptului
  JENKINS_ADMIN_PASSWORD="$ADMIN_PASS"
  JENKINS_ADMIN_TOKEN="$API_TOKEN"
}

# ── Creare job Jenkins ────────────────────────────────────────────────────────
create_jenkins_job() {
  local PORT="$1"
  local GITHUB_REPO="$2"
  local JOB_NAME="$3"
  local PASSWORD="${4:-}"

  cat > /tmp/jenkins-job.xml << XMLEOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>MDSSC Pipeline — ${JOB_NAME}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <com.cloudbees.jenkins.GitHubPushTrigger plugin="github">
          <spec></spec>
        </com.cloudbees.jenkins.GitHubPushTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${GITHUB_REPO}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>ci/Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
</flow-definition>
XMLEOF

  local AUTH_FLAG=""
  [ -n "$PASSWORD" ] && AUTH_FLAG="-u admin:${PASSWORD}"

  local cookie_jar="/tmp/jenkins-cookies-$$.txt"
  local resp_file="/tmp/jenkins-create-resp-$$.txt"

  # Obține CSRF crumb și salvează cookie-ul de sesiune
  local crumb_json CRUMB_VALUE CRUMB_FIELD
  # shellcheck disable=SC2086
  crumb_json=$(curl -sf $AUTH_FLAG \
    --cookie-jar "$cookie_jar" \
    "http://localhost:${PORT}/crumbIssuer/api/json" 2>/dev/null || echo "")
  CRUMB_VALUE=$(echo "$crumb_json" | grep -o '"crumb":"[^"]*"'             | sed 's/"crumb":"//;s/"//')
  CRUMB_FIELD=$(echo "$crumb_json" | grep -o '"crumbRequestField":"[^"]*"' | sed 's/"crumbRequestField":"//;s/"//')
  CRUMB_FIELD="${CRUMB_FIELD:-Jenkins-Crumb}"
  log_info "CSRF crumb: ${CRUMB_VALUE:-(none)}"

  local http_code
  if [ -n "$CRUMB_VALUE" ]; then
    # shellcheck disable=SC2086
    http_code=$(curl -s -w '%{http_code}' -o "$resp_file" -X POST $AUTH_FLAG \
      --cookie "$cookie_jar" \
      -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
      -H "Content-Type: application/xml" \
      --data-binary "@/tmp/jenkins-job.xml" \
      "http://localhost:${PORT}/createItem?name=${JOB_NAME}")
  else
    # shellcheck disable=SC2086
    http_code=$(curl -s -w '%{http_code}' -o "$resp_file" -X POST $AUTH_FLAG \
      -H "Content-Type: application/xml" \
      --data-binary "@/tmp/jenkins-job.xml" \
      "http://localhost:${PORT}/createItem?name=${JOB_NAME}")
  fi

  log_info "Jenkins createItem → HTTP ${http_code}"
  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    log_ok "Job '${JOB_NAME}' creat în Jenkins"
  else
    log_error "Creare job eșuată (HTTP ${http_code}):"
    cat "$resp_file" 2>/dev/null | head -20 || true
  fi
  rm -f "$cookie_jar" "$resp_file"
}

# ── Instalare via Docker ──────────────────────────────────────────────────────
install_docker_mode() {
  log_step "Instalare Jenkins via Docker"

  PROJECT_NAME=$(read_config "project_name" "mdssc-project")
  JENKINS_PORT=$(read_config "jenkins_port" "8080")
  JENKINS_URL=$(read_config "jenkins_url" "http://localhost:${JENKINS_PORT}")
  GITHUB_REPO=$(read_config "github_repo" "")
  JOB_NAME=$(read_config "jenkins_job" "${PROJECT_NAME}-pipeline")
  APP_PORT=$(read_config "app_port" "3001")

  # Extrage host-ul din jenkins_url
  JENKINS_HOST=$(echo "$JENKINS_URL" | sed 's|http[s]*://||' | cut -d: -f1 | cut -d/ -f1)

  # Avertisment localhost
  if [[ "$JENKINS_HOST" == "localhost" || "$JENKINS_HOST" == "127.0.0.1" ]]; then
    echo ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "  jenkins_url e setat pe localhost."
    log_warn "  GitHub Actions NU poate triggeriza un Jenkins local."
    log_warn ""
    log_warn "  Opțiuni:"
    log_warn "  1. Rulează pe un VPS cu IP public (recomandat)"
    log_warn "     → schimbă jenkins_url în pipeline.config.yml"
    log_warn "  2. Folosește ngrok pentru un tunel temporar:"
    log_warn "     ngrok http ${JENKINS_PORT}"
    log_warn "     → pune URL-ul ngrok în jenkins_url"
    log_warn "═══════════════════════════════════════════════════════"
    echo ""
  fi

  JENKINS_HOME="$HOME/.jenkins-data/${PROJECT_NAME}"
  mkdir -p "$JENKINS_HOME"
  log_ok "Date Jenkins: $JENKINS_HOME"

  # Verifică container existent
  if docker ps -a --format '{{.Names}}' | grep -q "^jenkins-${PROJECT_NAME}$"; then
    log_warn "Containerul jenkins-${PROJECT_NAME} există deja."
    echo -ne "  ${YELLOW}Vrei să îl recreezi? (y/N):${NC} "
    read -r RECREATE
    if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
      docker stop "jenkins-${PROJECT_NAME}" 2>/dev/null || true
      docker rm   "jenkins-${PROJECT_NAME}" 2>/dev/null || true
      log_ok "Container vechi șters"
    else
      log_info "Folosesc containerul existent."
      local CREDS_FILE="${JENKINS_HOME}/jenkins-credentials.txt"
      if [ -f "$CREDS_FILE" ]; then
        JENKINS_ADMIN_PASSWORD=$(grep "JENKINS_PASSWORD=" "$CREDS_FILE" | cut -d= -f2)
        JENKINS_ADMIN_TOKEN=$(grep "JENKINS_API_TOKEN=" "$CREDS_FILE" | cut -d= -f2)
        log_ok "Credențiale citite din: ${CREDS_FILE}"
      else
        setup_jenkins_security "$JENKINS_PORT" "$CREDS_FILE"
      fi
      if [ -n "$GITHUB_REPO" ]; then
        log_step "Creare job Jenkins"
        create_jenkins_job "$JENKINS_PORT" "$GITHUB_REPO" "$JOB_NAME" "${JENKINS_ADMIN_PASSWORD:-}"
      fi
      show_final_info "$JENKINS_URL" "$JENKINS_PORT" "$JOB_NAME" "${JENKINS_ADMIN_PASSWORD:-}" "${JENKINS_ADMIN_TOKEN:-}"
      return
    fi
  fi

  # Pornire Jenkins
  log_step "Pornire container Jenkins"
  FRONTEND_PORT=$((APP_PORT + 1))
  docker run -d \
    --name "jenkins-${PROJECT_NAME}" \
    --restart unless-stopped \
    -p "${JENKINS_PORT}:8080" \
    -p "50000:50000" \
    -p "${APP_PORT}:${APP_PORT}" \
    -p "${FRONTEND_PORT}:${FRONTEND_PORT}" \
    -v "${JENKINS_HOME}:/var/jenkins_home" \
    -v //var/run/docker.sock://var/run/docker.sock \
    -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
    --user root \
    jenkins/jenkins:lts-jdk21 > /dev/null
  log_ok "Container Jenkins pornit"

  wait_for_jenkins "$JENKINS_PORT"

  # Instalare plugin-uri
  log_step "Instalare plugin-uri Jenkins (${#JENKINS_PLUGINS[@]} plugin-uri)"
  local PLUGINS_STR="${JENKINS_PLUGINS[*]}"
  docker exec "jenkins-${PROJECT_NAME}" \
    jenkins-plugin-cli --plugins "$PLUGINS_STR" 2>&1 | \
    grep -E "(Installing|Done|Error|successfully|failed)" || true

  log_info "Restart Jenkins pentru activare plugin-uri..."
  docker restart "jenkins-${PROJECT_NAME}" > /dev/null
  sleep 10
  wait_for_jenkins "$JENKINS_PORT"
  log_ok "Plugin-uri instalate"

  # Instalare Node.js 20 și PM2 în container (necesar pentru build + deploy)
  log_step "Instalare Node.js 20 și PM2 în container Jenkins"
  docker exec "jenkins-${PROJECT_NAME}" bash -c "
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pm2"
  log_ok "Node.js $(docker exec jenkins-${PROJECT_NAME} node --version) și PM2 instalate"

  # Configurare securitate: creare user admin + generare API token
  local CREDS_FILE="${JENKINS_HOME}/jenkins-credentials.txt"
  setup_jenkins_security "$JENKINS_PORT" "$CREDS_FILE"

  # Creare job
  if [ -n "$GITHUB_REPO" ]; then
    log_step "Creare job Jenkins"
    create_jenkins_job "$JENKINS_PORT" "$GITHUB_REPO" "$JOB_NAME" "${JENKINS_ADMIN_PASSWORD:-}"
  else
    log_warn "github_repo nu e setat în pipeline.config.yml — job-ul Jenkins trebuie creat manual"
  fi

  show_final_info "$JENKINS_URL" "$JENKINS_PORT" "$JOB_NAME" "${JENKINS_ADMIN_PASSWORD:-}" "${JENKINS_ADMIN_TOKEN:-}"
}

# ── Instalare nativă Linux ────────────────────────────────────────────────────
install_linux_mode() {
  log_step "Instalare Jenkins pe Linux (apt)"

  if [ "$EUID" -ne 0 ]; then
    log_error "Instalarea nativă necesită sudo. Rulează: sudo ./setup-jenkins.sh"
    exit 1
  fi

  PROJECT_NAME=$(read_config "project_name" "mdssc-project")
  JENKINS_PORT=$(read_config "jenkins_port" "8080")
  JENKINS_URL=$(read_config "jenkins_url" "http://$(hostname -I | awk '{print $1}'):${JENKINS_PORT}")
  GITHUB_REPO=$(read_config "github_repo" "")
  JOB_NAME=$(read_config "jenkins_job" "${PROJECT_NAME}-pipeline")

  # Java
  log_step "Instalare Java 17"
  if java -version 2>&1 | grep -qE "17|21"; then
    log_ok "Java deja instalat"
  else
    apt-get update -qq
    apt-get install -y -qq openjdk-17-jdk
    log_ok "Java 17 instalat"
  fi

  # Jenkins repo
  log_step "Adăugare repository Jenkins"
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian-stable binary/" \
    | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

  # Instalare
  log_step "Instalare Jenkins"
  apt-get update -qq
  apt-get install -y -qq jenkins

  # Port custom
  if [ "$JENKINS_PORT" != "8080" ]; then
    sed -i "s/HTTP_PORT=8080/HTTP_PORT=${JENKINS_PORT}/" /etc/default/jenkins
    log_ok "Port configurat: $JENKINS_PORT"
  fi

  # Pornire
  log_step "Pornire serviciu Jenkins"
  systemctl enable jenkins
  systemctl start jenkins
  log_ok "Serviciu Jenkins pornit"

  wait_for_jenkins "$JENKINS_PORT"

  # Plugin-uri via CLI
  log_step "Instalare plugin-uri"
  JENKINS_CLI="/tmp/jenkins-cli.jar"
  curl -fsSL "http://localhost:${JENKINS_PORT}/jnlpJars/jenkins-cli.jar" -o "$JENKINS_CLI"
  INITIAL_PASSWORD=$(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "")

  for plugin in "${JENKINS_PLUGINS[@]}"; do
    java -jar "$JENKINS_CLI" \
      -s "http://localhost:${JENKINS_PORT}" \
      -auth "admin:${INITIAL_PASSWORD}" \
      install-plugin "$plugin" -deploy 2>/dev/null && \
      log_ok "  Plugin: $plugin" || \
      log_warn "  Plugin skipped: $plugin"
  done

  systemctl restart jenkins
  wait_for_jenkins "$JENKINS_PORT"
  log_ok "Plugin-uri instalate"

  # Creare job
  if [ -n "$GITHUB_REPO" ]; then
    log_step "Creare job Jenkins"
    create_jenkins_job "$JENKINS_PORT" "$GITHUB_REPO" "$JOB_NAME" "$INITIAL_PASSWORD"
  fi

  show_final_info "$JENKINS_URL" "$JENKINS_PORT" "$JOB_NAME" "$INITIAL_PASSWORD"
}

# ── Info finale ───────────────────────────────────────────────────────────────
show_final_info() {
  local JENKINS_URL="$1"
  local JENKINS_PORT="$2"
  local JOB_NAME="$3"
  local INITIAL_PASSWORD="$4"
  local API_TOKEN="${5:-}"

  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}   Jenkins instalat cu succes! ✓${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo ""
  echo -e "  ${BOLD}URL Jenkins:${NC}   ${JENKINS_URL}"
  echo -e "  ${BOLD}Job creat:${NC}     ${JOB_NAME}"
  echo ""
  if [ -n "$INITIAL_PASSWORD" ]; then
    echo -e "  ${BOLD}${YELLOW}User Jenkins:${NC}          admin"
    echo -e "  ${BOLD}${YELLOW}Parolă Jenkins:${NC}        ${INITIAL_PASSWORD}"
    echo ""
  fi
  if [ -n "$API_TOKEN" ]; then
    echo -e "  ${BOLD}${YELLOW}JENKINS_API_TOKEN:${NC}     ${API_TOKEN}"
    echo -e "  ${CYAN}→ Adaugă direct ca secret GitHub: JENKINS_API_TOKEN${NC}"
    echo ""
  fi
  echo -e "  ${BOLD}Pași următori:${NC}"
  echo -e "  ${CYAN}1.${NC} Deschide ${JENKINS_URL} în browser"
  echo -e "  ${CYAN}2.${NC} Adaugă credențialele MDSSC în Jenkins:"
  echo -e "     Manage Jenkins → Credentials → Global → Add:"
  echo -e "     • Kind: Secret text"
  echo -e "     • ID: mdssc-api-key"
  echo -e "     • Secret: API key-ul tău MDSSC"
  echo -e "  ${CYAN}3.${NC} Adaugă secretele Jenkins în GitHub repo:"
  echo -e "     Settings → Secrets → Actions:"
  echo -e "     • JENKINS_VPS_URL  = ${JENKINS_URL}"
  echo -e "     • JENKINS_USER     = admin"
  echo -e "     • JENKINS_API_TOKEN = (generat din Jenkins → User → Configure)"
  echo -e "  ${CYAN}4.${NC} Fă un push pe main și urmărește pipeline-ul în GitHub Actions"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  header
  check_deps
  detect_mode

  case "$INSTALL_MODE" in
    docker) install_docker_mode ;;
    linux)  install_linux_mode  ;;
  esac
}

main "$@"