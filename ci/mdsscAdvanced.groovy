// ============================================================
// MDSSC Advanced API Wrapper — GreenCart Grocery
//
// API methods used:
//   1. GET  /api/v1/health (+ /version + /scans?limit=1 fallbacks)
//   2. GET  /api/v1/workflows             — list all workflows (auto-detect default)
//   3. GET  /api/v1/workflows/{workflowId}
//   4. POST /api/v1/scans/direct          — upload file directly
//   5. GET  /api/v1/scans/{scanId}/overview — rich poll (progress %, malware, secrets, blocked-licenses)
//   6. GET  /api/v1/scans/{scanId}         — full detailed results
//   7. POST /api/v1/scans                  — indirect scan by repository reference (no file upload)
// ============================================================

// ---- Private helpers ----

String _paramValue(String name, String defaultValue = '') {
    def value = params[name]
    if (value == null) return defaultValue
    String text = value.toString().trim()
    return text ? text : defaultValue
}

String _shellQuote(String value) {
    return "'${value.replace("'", "'\"'\"'")}'"
}

String _apiBaseUrl(String server) {
    String s = server.replaceAll('/+$', '')
    if (s.endsWith('/api/v1')) return s
    if (s.endsWith('/api'))   return "${s}/v1"
    return "${s}/api/v1"
}

String _server(Map config) {
    return config.server?.toString()?.trim() ?: _paramValue('MDSSC_SERVER', 'http://35.156.106.42')
}

String _credId(Map config) {
    return config.credentialsId?.toString()?.trim() ?: _paramValue('MDSSC_CREDENTIALS_ID', 'mdssc-api-key')
}

String _apiKeyHeader(Map config) {
    return config.apiKeyHeader?.toString()?.trim() ?: _paramValue('MDSSC_API_KEY_HEADER', 'apikey')
}

String _scanTimeout(Map config) {
    return config.scanTimeout?.toString()?.trim() ?: _paramValue('MDSSC_SCAN_TIMEOUT', '900')
}

String _pollInterval(Map config) {
    return config.pollInterval?.toString()?.trim() ?: _paramValue('MDSSC_POLL_INTERVAL', '10')
}

String _threshold(Map config) {
    return (config.vulnerabilityThreshold?.toString()?.trim() ?: _paramValue('MDSSC_VULNERABILITY_THRESHOLD', 'critical')).toLowerCase()
}

boolean _failOnVuln(Map config) {
    if (config.failOnVulnerabilities != null) return config.failOnVulnerabilities as boolean
    return params.MDSSC_FAIL_ON_VULNERABILITIES == null ? false : params.MDSSC_FAIL_ON_VULNERABILITIES as boolean
}

String _workflowId(Map config) {
    return config.workflowId?.toString()?.trim() ?: _paramValue('MDSSC_WORKFLOW_ID', '')
}

String _overviewParserScript(String overviewFile, String stateFile, String label) {
    return """
        const fs = require('fs');
        const raw = fs.readFileSync(${_shellQuote(overviewFile)}, 'utf8');
        const data = JSON.parse(raw);

        const state =
            data.ScanningState     || data.scanningState     ||
            data.scanStatus?.scanningState ||
            data.ScanStatus?.ScanningState ||
            data.status            || data.Status            || 'Unknown';

        const progress  = data.ScanProgress        ?? data.scanProgress        ?? '?';
        const critical  = data.critical             ?? data.Critical            ?? data.vulnerabilityIssues?.critical  ?? 0;
        const high      = data.high                 ?? data.High                ?? data.vulnerabilityIssues?.high      ?? 0;
        const medium    = data.medium               ?? data.Medium              ?? data.vulnerabilityIssues?.medium    ?? 0;
        const low       = data.low                  ?? data.Low                 ?? data.vulnerabilityIssues?.low       ?? 0;
        const malware   = data.Malware              ?? data.malware             ?? 0;
        const secrets   = data.Secret               ?? data.secret              ?? data.Secrets ?? data.secrets ?? 0;
        const blockedLic= data.BlockedLicensesCount ?? data.blockedLicensesCount ?? 0;
        const elapsed   = process.env.ELAPSED || '0';

        const prog = progress !== '?' ? ' (' + progress + '%)' : '';
        const line = '[' + elapsed + 's] ${label} | ' + state + prog +
            ' | Vuln C:' + critical + ' H:' + high + ' M:' + medium + ' L:' + low +
            ' | Malware:' + malware + ' Secrets:' + secrets + ' BlockedLic:' + blockedLic;
        console.log(line);

        fs.writeFileSync(${_shellQuote(stateFile)}, String(state));

        const normalized = String(state).toLowerCase();
        if (['completed','complete','finished','done','success'].includes(normalized)) process.exit(0);
        if (['failed','failure','error','cancelled','canceled'].includes(normalized))  process.exit(2);
        process.exit(1);
    """
}

String _pollLoopShell(String baseUrl, String header, String scanTimeout, String pollInterval,
                      String overviewFile, String stateFile, String label) {
    String parserScript = _overviewParserScript(overviewFile, stateFile, label)
    return """
        elapsed=0
        while [ "\$elapsed" -le ${_shellQuote(scanTimeout)} ]; do
            ov_code=\$(curl -sS -w '%{http_code}' -o ${_shellQuote(overviewFile)} \\
                --max-time 30 \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                -H 'Content-Type: application/json' \\
                ${_shellQuote(baseUrl)}"/\$scan_id/overview")

            if [ "\$ov_code" -lt 200 ] || [ "\$ov_code" -ge 300 ]; then
                ov_code=\$(curl -sS -w '%{http_code}' -o ${_shellQuote(overviewFile)} \\
                    --max-time 30 \\
                    -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                    ${_shellQuote(baseUrl)}"/\$scan_id")
            fi

            if [ "\$ov_code" -lt 200 ] || [ "\$ov_code" -ge 300 ]; then
                echo "MDSSC poll failed for '${label}'. HTTP \$ov_code"
                cat ${_shellQuote(overviewFile)} || true
                exit 1
            fi

            node -e ${_shellQuote(parserScript)} && break || node_exit=\$?

            if [ "\${node_exit:-0}" -eq 2 ]; then
                echo "MDSSC scan error for '${label}'."
                cat ${_shellQuote(overviewFile)} || true
                exit 1
            fi

            sleep ${pollInterval}
            elapsed=\$((elapsed + ${pollInterval}))
            export ELAPSED="\$elapsed"
        done

        if [ "\$elapsed" -gt ${scanTimeout} ]; then
            echo "MDSSC scan timed out for '${label}' after ${scanTimeout}s."
            exit 1
        fi
    """
}

String _summaryScript(String resultFile, String overviewFile, String scanIdFile,
                      String label, String threshold, boolean failOnVuln) {
    return """
        const fs = require('fs');
        let result  = {};
        let overview = {};
        try { result   = JSON.parse(fs.readFileSync(${_shellQuote(resultFile)},  'utf8')); } catch(e) {}
        try { overview = JSON.parse(fs.readFileSync(${_shellQuote(overviewFile)}, 'utf8')); } catch(e) {}
        const scanId = fs.readFileSync(${_shellQuote(scanIdFile)}, 'utf8').trim();

        const iss = result.vulnerabilityIssues || result.VulnerabilityIssues ||
                    result.scanInformation?.vulnerabilityIssues || {};
        const counts = {
            critical : Number(iss.critical  ?? iss.Critical  ?? overview.critical  ?? overview.Critical  ?? 0),
            high     : Number(iss.high      ?? iss.High      ?? overview.high      ?? overview.High      ?? 0),
            medium   : Number(iss.medium    ?? iss.Medium    ?? overview.medium    ?? overview.Medium    ?? 0),
            low      : Number(iss.low       ?? iss.Low       ?? overview.low       ?? overview.Low       ?? 0),
        };
        const malware    = Number(overview.Malware              ?? overview.malware              ?? result.malware    ?? 0);
        const secrets    = Number(overview.Secret               ?? overview.secret               ?? result.secrets    ?? 0);
        const blockedLic = Number(overview.BlockedLicensesCount ?? overview.blockedLicensesCount ?? 0);
        const state      = overview.ScanningState || overview.scanningState ||
                           result.scanStatus?.scanningState || 'N/A';

        const line = (s, v) => console.log(s.padEnd(20) + v);
        console.log('');
        console.log('==========================================');
        console.log('        MDSSC SCAN REPORT');
        console.log('==========================================');
        line('Label:',       '${label}');
        line('Scan ID:',     scanId);
        line('Final State:', state);
        console.log('------------------------------------------');
        console.log('VULNERABILITIES:');
        line('  Critical:',  counts.critical);
        line('  High:',      counts.high);
        line('  Medium:',    counts.medium);
        line('  Low:',       counts.low);
        console.log('------------------------------------------');
        console.log('OTHER FINDINGS:');
        line('  Malware:',         malware);
        line('  Secrets:',         secrets);
        line('  Blocked Licenses:',blockedLic);
        console.log('==========================================');
        console.log('');

        const order     = ['low','medium','high','critical'];
        const threshIdx = order.indexOf(${_shellQuote(threshold)});
        const failing   = threshIdx >= 0 && order.filter(s => order.indexOf(s) >= threshIdx).some(s => counts[s] > 0);
        if (${failOnVuln} && failing) {
            console.error('FAIL: Vulnerabilities found at or above threshold: ${threshold}');
            process.exit(2);
        }
    """
}

void checkHealth(Map config = [:]) {
    String server  = _server(config)
    String baseUrl = _apiBaseUrl(server)
    String header  = _apiKeyHeader(config)

    withCredentials([string(credentialsId: _credId(config), variable: 'MDSSC_API_KEY')]) {
        sh """
            set -eu
            echo "=========================================="
            echo "MDSSC API Health Check — ${server}"
            echo "=========================================="

            try_endpoint() {
                local path="\$1"
                local desc="\$2"
                code=\$(curl -sS -w '%{http_code}' -o .mdssc-hc.json \\
                    --max-time 15 \\
                    -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                    ${_shellQuote(baseUrl)}"\$path" 2>/dev/null) || code=0
                echo "GET \$path -> HTTP \$code (\$desc)"
                if [ "\$code" -ge 200 ] && [ "\$code" -lt 300 ]; then
                    echo "Response:"
                    cat .mdssc-hc.json 2>/dev/null || true
                    echo ""
                    return 0
                fi
                return 1
            }

            try_endpoint "/health"        "health endpoint"  && exit 0 || true
            try_endpoint "/version"       "version endpoint" && exit 0 || true
            try_endpoint "/scans?limit=1" "scans list (connectivity probe)" && exit 0 || true

            echo "WARNING: Could not confirm MDSSC server health. Continuing pipeline."
        """
    }
}

String _resolveWorkflowId(Map config, String baseUrl, String header) {
    String wfId = _workflowId(config)
    if (wfId) return wfId

    echo "MDSSC: No MDSSC_WORKFLOW_ID set — fetching default workflow from list..."

    withCredentials([string(credentialsId: _credId(config), variable: 'MDSSC_API_KEY')]) {
        sh """
            set -eu
            http_code=\$(curl -sS -w '%{http_code}' -o .mdssc-workflows-list.json \\
                --max-time 30 \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                -H 'Content-Type: application/json' \\
                ${_shellQuote("${baseUrl}/workflows")})
            echo "GET /workflows -> HTTP \$http_code"

            if [ "\$http_code" -lt 200 ] || [ "\$http_code" -ge 300 ]; then
                echo "WARNING: Could not fetch workflows list (HTTP \$http_code)."
                echo "" > .mdssc-wf-auto-id.txt
            else
                node -e "
                    const fs = require('fs');
                    const raw = JSON.parse(fs.readFileSync('.mdssc-workflows-list.json', 'utf8'));
                    const list = Array.isArray(raw) ? raw
                               : (raw.workflows || raw.Workflows || raw.data || raw.Data || []);
                    const getId  = w => w.id || w.Id || w.WorkflowId || w.workflowId || '';
                    const getName = w => w.name || w.Name || w.WorkflowName || w.workflowName || '';
                    const found  = list.find(w => getName(w) === 'github-ioana');
                    const def    = found || list[0] || {};
                    const id     = getId(def);
                    console.log('Available workflows: ' + list.map(w => getName(w) + '(' + getId(w) + ')').join(', '));
                    console.log('Selected workflow: ' + getName(def) + ' — ID: ' + id);
                    fs.writeFileSync('.mdssc-wf-auto-id.txt', String(id));
                "
            fi
        """
    }

    return sh(script: 'cat .mdssc-wf-auto-id.txt 2>/dev/null || echo ""', returnStdout: true).trim()
}

Map fetchWorkflow(Map config = [:]) {
    String server  = _server(config)
    String baseUrl = _apiBaseUrl(server)
    String header  = _apiKeyHeader(config)

    String workflowId = _resolveWorkflowId(config, baseUrl, header)
    if (!workflowId) {
        echo "MDSSC: No workflow found — skipping workflow fetch."
        return [storageId: '', repositoryId: '', repositoryName: '', workflowName: '']
    }

    withCredentials([string(credentialsId: _credId(config), variable: 'MDSSC_API_KEY')]) {
        sh """
            set -eu
            echo "=========================================="
            echo "MDSSC Fetch Workflow: ${workflowId}"
            echo "=========================================="

            http_code=\$(curl -sS -w '%{http_code}' -o .mdssc-workflow.json \\
                --max-time 30 \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                -H 'Content-Type: application/json' \\
                ${_shellQuote("${baseUrl}/workflows/${workflowId}")})

            echo "GET /workflows/${workflowId} -> HTTP \$http_code"

            if [ "\$http_code" -lt 200 ] || [ "\$http_code" -ge 300 ]; then
                echo "WARNING: Could not fetch workflow details (HTTP \$http_code). Continuing."
                echo "" > .mdssc-wf-storageId.txt
                echo "" > .mdssc-wf-repositoryId.txt
                echo "" > .mdssc-wf-repositoryName.txt
                echo "" > .mdssc-wf-workflowName.txt
            else
                node -e "
                    const fs = require('fs');
                    const data = JSON.parse(fs.readFileSync('.mdssc-workflow.json', 'utf8'));

                    const sources   = data.ScanSources   || data.scanSources   || [];
                    const firstSrc  = Array.isArray(sources)  ? sources[0]  : (sources  || {});
                    const storageId = firstSrc.ServiceId      || firstSrc.serviceId      ||
                                      data.ServiceId          || data.serviceId          || '';

                    const repos     = firstSrc.Repositories   || firstSrc.repositories   ||
                                      data.Repositories       || data.repositories       || [];
                    const firstRepo = Array.isArray(repos)    ? repos[0]    : (repos    || {});
                    const repoId    = firstRepo.RepositoryId  || firstRepo.repositoryId  ||
                                      firstRepo.Id            || firstRepo.id            || '';
                    const repoName  = firstRepo.RepositoryName|| firstRepo.repositoryName||
                                      firstRepo.Name          || firstRepo.name          || '';

                    const wfName    = data.Name           || data.name           ||
                                      data.WorkflowName   || data.workflowName   || '${workflowId}';

                    fs.writeFileSync('.mdssc-wf-storageId.txt',     storageId);
                    fs.writeFileSync('.mdssc-wf-repositoryId.txt',   repoId);
                    fs.writeFileSync('.mdssc-wf-repositoryName.txt', repoName);
                    fs.writeFileSync('.mdssc-wf-workflowName.txt',   wfName);
                "
            fi
        """
    }

    return [
        workflowId    : workflowId,
        storageId     : sh(script: 'cat .mdssc-wf-storageId.txt     2>/dev/null || echo ""', returnStdout: true).trim(),
        repositoryId  : sh(script: 'cat .mdssc-wf-repositoryId.txt  2>/dev/null || echo ""', returnStdout: true).trim(),
        repositoryName: sh(script: 'cat .mdssc-wf-repositoryName.txt 2>/dev/null || echo ""', returnStdout: true).trim(),
        workflowName  : sh(script: 'cat .mdssc-wf-workflowName.txt  2>/dev/null || echo ""', returnStdout: true).trim(),
    ]
}

String scanFileDirect(Map config = [:]) {
    String filePath = config.path?.toString()
    if (!filePath) error('MDSSC scanFileDirect: config.path is required.')

    String label        = config.label?.toString() ?: filePath
    String server       = _server(config)
    String baseUrl      = _apiBaseUrl(server)
    String header       = _apiKeyHeader(config)
    String scanTimeout  = _scanTimeout(config)
    String pollInterval = _pollInterval(config)
    String threshold    = _threshold(config)
    boolean failOnVuln  = _failOnVuln(config)
    String wfId         = _workflowId(config)
    String prefix       = ".mdssc-${label.replaceAll('[^A-Za-z0-9_.-]', '-')}"
    String wfForm       = wfId ? "-F workflowId=${_shellQuote(wfId)}" : ''
    String meta         = "{\"source\":\"jenkins\",\"label\":\"${label.replace('"', '\\"')}\"}"
    String metaForm     = "-F metadata=${_shellQuote(meta)}"
    String scansBase    = "${baseUrl}/scans"
    String pollLoop     = _pollLoopShell(scansBase, header, scanTimeout, pollInterval,
                              "${prefix}-overview.json", "${prefix}-state.txt", label)
    String summary      = _summaryScript("${prefix}-result.json", "${prefix}-overview.json",
                              "${prefix}-scan-id.txt", label, threshold, failOnVuln)

    withCredentials([string(credentialsId: _credId(config), variable: 'MDSSC_API_KEY')]) {
        sh """
            set -eu
            echo "=========================================="
            echo "MDSSC Direct Scan: ${label}"
            echo "File: ${filePath}"
            echo "=========================================="

            sub_code=\$(curl -sS -w '%{http_code}' -o ${_shellQuote("${prefix}-submit.json")} \\
                --max-time 300 \\
                -X POST ${_shellQuote("${baseUrl}/scans/direct")} \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                -F file=@${_shellQuote(filePath)} \\
                ${wfForm} \\
                ${metaForm})

            echo "POST /scans/direct -> HTTP \$sub_code"

            if [ "\$sub_code" -lt 200 ] || [ "\$sub_code" -ge 300 ]; then
                echo "MDSSC direct upload failed for '${label}'. HTTP \$sub_code"
                cat ${_shellQuote("${prefix}-submit.json")} || true
                exit 1
            fi

            node -e "
                const fs = require('fs');
                const data = JSON.parse(fs.readFileSync(${_shellQuote("${prefix}-submit.json")}, 'utf8'));
                const ids  = data.scanIds || data.ScanIds || data.ScanIDs || data.scanIDs;
                const id   = Array.isArray(ids) ? ids[0]
                           : (data.scanId || data.ScanId || data.id || data.Id || '');
                if (!id) { console.error('No scan ID in MDSSC response'); process.exit(1); }
                fs.writeFileSync(${_shellQuote("${prefix}-scan-id.txt")}, String(id));
                console.log('Scan ID: ' + id);
            "

            scan_id=\$(cat ${_shellQuote("${prefix}-scan-id.txt")})
            ${pollLoop}

            res_code=\$(curl -sS -w '%{http_code}' -o ${_shellQuote("${prefix}-result.json")} \\
                --max-time 30 \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                ${_shellQuote(scansBase)}"/\$scan_id")

            node -e ${_shellQuote(summary)}
        """
    }

    return sh(script: "cat ${_shellQuote("${prefix}-scan-id.txt")} 2>/dev/null || echo ''", returnStdout: true).trim()
}

String scanRepositoryIndirect(Map config = [:], Map workflowInfo = [:]) {
    String wfId       = _workflowId(config)
    String storageId  = (workflowInfo.storageId    ?: config.storageId    ?: '').toString().trim()
    String repoId     = (workflowInfo.repositoryId ?: config.repositoryId ?: '').toString().trim()
    String branchName = (config.branch ?: env.BRANCH_NAME ?: 'main').toString().trim()
    String label      = (config.label ?: "repo-${branchName}").toString()

    if (!wfId || !storageId || !repoId) {
        echo "MDSSC indirect scan skipped — needs workflowId + storageId + repositoryId."
        return ''
    }

    String server       = _server(config)
    String baseUrl      = _apiBaseUrl(server)
    String header       = _apiKeyHeader(config)
    String scanTimeout  = _scanTimeout(config)
    String pollInterval = _pollInterval(config)
    String threshold    = _threshold(config)
    boolean failOnVuln  = _failOnVuln(config)
    String prefix       = ".mdssc-${label.replaceAll('[^A-Za-z0-9_.-]', '-')}"
    String scansBase    = "${baseUrl}/scans"
    String pollLoop     = _pollLoopShell(scansBase, header, scanTimeout, pollInterval,
                              "${prefix}-overview.json", "${prefix}-state.txt", label)
    String summary      = _summaryScript("${prefix}-result.json", "${prefix}-overview.json",
                              "${prefix}-scan-id.txt", label, threshold, failOnVuln)

    String bodyJson = (
        '{' +
        '"StorageId":"'    + storageId  + '",' +
        '"ScanType":"Instant",'               +
        '"WorkflowId":"'   + wfId       + '",' +
        '"RepositoryId":"' + repoId     + '",' +
        '"RepositoryReferences":["' + branchName + '"]' +
        '}'
    )

    withCredentials([string(credentialsId: _credId(config), variable: 'MDSSC_API_KEY')]) {
        sh """
            set -eu
            echo "=========================================="
            echo "MDSSC Indirect Scan: ${label} (branch: ${branchName})"
            echo "=========================================="

            sub_code=\$(curl -sS -w '%{http_code}' -o ${_shellQuote("${prefix}-submit.json")} \\
                --max-time 60 \\
                -X POST ${_shellQuote("${baseUrl}/scans")} \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                -H 'Content-Type: application/json' \\
                -d ${_shellQuote(bodyJson)})

            echo "POST /scans (indirect) -> HTTP \$sub_code"

            if [ "\$sub_code" -lt 200 ] || [ "\$sub_code" -ge 300 ]; then
                echo "WARNING: Indirect scan submission failed (HTTP \$sub_code). Skipping."
                echo "" > ${_shellQuote("${prefix}-scan-id.txt")}
                exit 0
            fi

            node -e "
                const fs = require('fs');
                const data = JSON.parse(fs.readFileSync(${_shellQuote("${prefix}-submit.json")}, 'utf8'));
                const ids  = data.ScanIds || data.scanIds || data.ScanIDs || data.scanIDs;
                const id   = Array.isArray(ids) ? ids[0]
                           : (data.scanId || data.ScanId || data.id || data.Id || '');
                fs.writeFileSync(${_shellQuote("${prefix}-scan-id.txt")}, String(id || ''));
                if (id) console.log('Indirect scan ID: ' + id);
                else console.log('No scan ID returned.');
            "

            scan_id=\$(cat ${_shellQuote("${prefix}-scan-id.txt")})
            if [ -z "\$scan_id" ]; then exit 0; fi

            ${pollLoop}

            res_code=\$(curl -sS -w '%{http_code}' -o ${_shellQuote("${prefix}-result.json")} \\
                --max-time 30 \\
                -H ${_shellQuote("${header}: ")}"\$MDSSC_API_KEY" \\
                ${_shellQuote(scansBase)}"/\$scan_id")

            node -e ${_shellQuote(summary)}
        """
    }

    return sh(script: "cat ${_shellQuote("${prefix}-scan-id.txt")} 2>/dev/null || echo ''", returnStdout: true).trim()
}

List<String> scanArtifacts(Map config = [:]) {
    String artifactDir  = config.artifactDir?.toString() ?: 'artifacts'
    List   excludeNames = config.excludeNames ?: []
    String excludeArgs  = excludeNames.collect { "! -name ${_shellQuote(it.toString())}" }.join(' ')
    String skipLarge    = _paramValue('MDSSC_SKIP_LARGE_ARTIFACTS', 'true')
    String maxMb        = _paramValue('MDSSC_MAX_UPLOAD_MB', '100')

    sh """
        find ${_shellQuote(artifactDir)} -maxdepth 1 -type f ${excludeArgs} -print | while IFS= read -r f; do
            size=\$(wc -c < "\$f")
            max=\$(( ${maxMb} * 1024 * 1024 ))
            if [ ${_shellQuote(skipLarge)} = "true" ] && [ "\$size" -gt "\$max" ]; then
                echo "Skipping large artifact: \$f" >&2; continue
            fi
            echo "\$f"
        done > .mdssc-artifacts-to-scan
    """

    String list = sh(script: 'cat .mdssc-artifacts-to-scan 2>/dev/null || echo ""', returnStdout: true).trim()
    if (!list) { echo "MDSSC: no artifact files selected."; return [] }

    List<String> scanIds = []
    list.split('\n').findAll { it.trim() }.each { artifact ->
        String name = artifact.tokenize('/').last()
        String sid  = scanFileDirect(config + [path: artifact.trim(), label: "artifact-${name}"])
        if (sid) scanIds << sid
    }
    return scanIds
}

void printFinalSummary(Map config = [:], List<String> scanIds, String repositoryId = '') {
    String server    = _server(config)
    String cleanBase = server.replaceAll('/+$', '').replaceAll('/api(/v\\d+)?$', '')

    echo '=========================================='
    echo '   MDSSC PIPELINE SUMMARY'
    echo '=========================================='
    echo "Server      : ${server}"
    echo "Scans total : ${scanIds.findAll { it }.size()}"
    echo '------------------------------------------'
    scanIds.findAll { it }.eachWithIndex { id, idx ->
        echo "  [${idx+1}] Scan ID : ${id}"
        if (repositoryId) echo "       Report  : ${cleanBase}/reports/${repositoryId}/${id}"
    }
    echo '=========================================='
}

return this
