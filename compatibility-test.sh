#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# compatibility-test.sh
#
# Flow per repo:
#   1. Fetch all open patch MRs (label: 'patch' — as set by renovate-config.js)
#   2. Filter out already-tested MRs (labels: 'compatibility-test-success' / 'compatibility-test-failed')
#   3. Sort oldest-first
#   4. For each MR:
#      a. Clone the MR source branch
#      b. Rebase onto current base branch
#         - If rebase conflict → post note, label, skip to next MR
#         - If clean → force-push rebased branch to GitLab
#      c. Detect changed manifest files from MR diff
#      d. Run relevant dry-run resolver (pip / npm / mvn / dockerfile)
#         - Dockerfile gets both tag existence + OS compatibility check
#         - If pass → post success note, automerge (squash), label
#         - If fail → post failure note, label
#      e. If merged, base branch now updated — next MR rebases on top
#
# Output:
#   Prints structured COMPAT_RESULT and COMPAT_* lines to stdout
#   for the Jenkins email stage to parse from the build log.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

DEBUG="${DEBUG:-false}"

debug() {
    if [ "${DEBUG}" = "true" ]; then
        echo "[DEBUG] $*"
    fi
}

GITLAB_API="${GITLAB_API:-https://gitlab.example.com/api/v4}"
TOKEN="${GITLAB_TOKEN}"
BUILD_URL="${BUILD_URL:-unknown}"
GIT_BASE_URL="https://renovate-bot:${TOKEN}@gitlab.example.com"

# ── Target repos ─────────────────────────────────────────────────────────────
REPOS=(
    "your repo path here"
)

# ── Base branch (must match baseBranches in renovate-config.js) ──────────────
BASE_BRANCH="develop"

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

url_encode() {
    echo "$1" | sed 's/\//%2F/g'
}

gitlab_get() {
    local url="$1"
    debug "GET ${url}"
    local response
    response=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" "${url}")
    local exit_code=$?
    debug "GET exit_code=${exit_code} response_length=${#response}"
    echo "${response}"
    return ${exit_code}
}

gitlab_post() {
    local url="$1"
    local data="$2"
    debug "POST ${url}"
    local response
    response=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" \
         --header "Content-Type: application/json" \
         --request POST \
         --data "${data}" \
         "${url}")
    local exit_code=$?
    debug "POST exit_code=${exit_code}"
    echo "${response}"
    return ${exit_code}
}

gitlab_put() {
    local url="$1"
    local data="$2"
    debug "PUT ${url}"
    local response
    response=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" \
         --header "Content-Type: application/json" \
         --request PUT \
         --data "${data}" \
         "${url}")
    local exit_code=$?
    debug "PUT exit_code=${exit_code} response=${response}"
    echo "${response}"
    return ${exit_code}
}

# ── Post a note on an MR ────────────────────────────────────────────────────

post_mr_note() {
    local encoded_path="$1"
    local mr_iid="$2"
    local body="$3"

    local escaped_body
    escaped_body=$(echo "${body}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    gitlab_post \
        "${GITLAB_API}/projects/${encoded_path}/merge_requests/${mr_iid}/notes" \
        "{\"body\": ${escaped_body}}"
}

# ── Add label(s) to an MR ───────────────────────────────────────────────────

add_mr_labels() {
    local encoded_path="$1"
    local mr_iid="$2"
    shift 2
    local new_labels="$*"

    local current_labels
    current_labels=$(gitlab_get "${GITLAB_API}/projects/${encoded_path}/merge_requests/${mr_iid}" \
        | jq -r '.labels | join(",")')

    local all_labels="${current_labels}"
    for label in ${new_labels}; do
        all_labels="${all_labels},${label}"
    done

    gitlab_put \
        "${GITLAB_API}/projects/${encoded_path}/merge_requests/${mr_iid}" \
        "{\"labels\": \"${all_labels}\"}"
}

# ── Squash-merge an MR ──────────────────────────────────────────────────────

automerge_mr() {
    local encoded_path="$1"
    local mr_iid="$2"

    gitlab_put \
        "${GITLAB_API}/projects/${encoded_path}/merge_requests/${mr_iid}/merge" \
        "{\"squash\": true, \"should_remove_source_branch\": true}"
}

# ── Get changed files in an MR ──────────────────────────────────────────────

get_mr_changed_files() {
    local encoded_path="$1"
    local mr_iid="$2"

    gitlab_get "${GITLAB_API}/projects/${encoded_path}/merge_requests/${mr_iid}/changes" \
        | jq -r '.changes[].new_path'
}

# ── Get version bump info from MR description ───────────────────────────────

get_version_bumps() {
    local encoded_path="$1"
    local mr_iid="$2"

    gitlab_get "${GITLAB_API}/projects/${encoded_path}/merge_requests/${mr_iid}" \
        | jq -r '.description // "(no description)"'
}

# ─────────────────────────────────────────────────────────────────────────────
# REBASE FUNCTION
# ─────────────────────────────────────────────────────────────────────────────

rebase_mr_branch() {
    local repo="$1"
    local source_branch="$2"
    local work_dir="$3"

    echo "   Cloning ${source_branch}..."
    debug "Clone URL: ${GIT_BASE_URL}/${repo}.git branch=${source_branch} into ${work_dir}"
    local clone_output
    clone_output=$(git clone \
        --branch "${source_branch}" \
        "${GIT_BASE_URL}/${repo}.git" \
        "${work_dir}" 2>&1)
    local clone_exit=$?
    echo "${clone_output}" | tail -2
    debug "Clone exit_code=${clone_exit}"
    if [ "${clone_exit}" -ne 0 ]; then
        echo "   ❌ Clone failed (exit ${clone_exit})"
        echo "${clone_output}"
        return 1
    fi

    cd "${work_dir}"
    debug "HEAD commit: $(git rev-parse HEAD) on branch $(git rev-parse --abbrev-ref HEAD)"

    echo "   Fetching latest ${BASE_BRANCH}..."
    git fetch origin "${BASE_BRANCH}" 2>&1 | tail -2
    debug "origin/${BASE_BRANCH} is at: $(git rev-parse origin/${BASE_BRANCH})"

    local behind_count
    behind_count=$(git rev-list --count "HEAD..origin/${BASE_BRANCH}")
    debug "Commits behind ${BASE_BRANCH}: ${behind_count}"

    if [ "${behind_count}" -eq 0 ]; then
        echo "   Branch is up-to-date with ${BASE_BRANCH} — no rebase needed"
        cd - > /dev/null
        return 0
    fi

    echo "   Branch is ${behind_count} commit(s) behind ${BASE_BRANCH} — rebasing..."

    local rebase_output
    rebase_output=$(git rebase "origin/${BASE_BRANCH}" 2>&1)
    local rebase_exit=$?
    debug "Rebase exit_code=${rebase_exit}"
    echo "${rebase_output}"

    if [ "${rebase_exit}" -ne 0 ]; then
        echo "   ❌ Rebase conflict detected"
        debug "Rebase output: ${rebase_output}"
        git rebase --abort 2>/dev/null
        cd - > /dev/null
        return 1
    fi

    echo "   ✅ Rebase clean — force-pushing to origin/${source_branch}..."

    local push_output
    push_output=$(git push --force origin "${source_branch}" 2>&1)
    local push_exit=$?
    debug "Force-push exit_code=${push_exit}"
    echo "${push_output}"

    if [ "${push_exit}" -ne 0 ]; then
        echo "   ❌ Force-push failed"
        debug "Push output: ${push_output}"
        cd - > /dev/null
        return 2
    fi

    echo "   ✅ Force-push successful"
    cd - > /dev/null
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# RESOLVER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

test_requirements_txt() {
    local repo_dir="$1"

    local req_files
    req_files=$(find "${repo_dir}" -name "requirements*.txt" \
        -not -path "*/node_modules/*" \
        -not -path "*/.venv/*" \
        -not -path "*/__pycache__/*" 2>/dev/null)

    if [ -z "${req_files}" ]; then
        echo "SKIP: No requirements.txt found"
        return 0
    fi

    local all_pass=true
    local combined_output=""

    while IFS= read -r req_file; do
        echo "   ── Testing pip: ${req_file}"
        debug "pip dry-run for: ${req_file}"

        local output
        output=$(python3 -m pip install \
            --dry-run \
            --ignore-installed \
            -r "${req_file}" \
            2>&1)
        local exit_code=$?
        debug "pip exit_code=${exit_code}"

        if [ "${exit_code}" -ne 0 ]; then
            echo "   ❌ pip conflict in ${req_file}"
            echo "${output}"
            all_pass=false
            combined_output="${combined_output}\n--- ${req_file} ---\n${output}"
        else
            echo "   ✅ pip: ${req_file} resolves cleanly"
            debug "pip output (last 5 lines): $(echo "${output}" | tail -5)"
        fi
    done <<< "${req_files}"

    if [ "${all_pass}" = true ]; then
        return 0
    else
        echo "${combined_output}"
        return 1
    fi
}

test_package_json() {
    local repo_dir="$1"

    local pkg_file="${repo_dir}/package.json"
    if [ ! -f "${pkg_file}" ]; then
        echo "SKIP: package.json not found"
        return 0
    fi

    echo "   ── Testing npm: ${pkg_file}"
    debug "npm dry-run in: ${repo_dir}"

    local output
    cd "${repo_dir}"
    output=$(npm install --dry-run 2>&1)
    local exit_code=$?
    cd - > /dev/null
    debug "npm exit_code=${exit_code}"

    if [ "${exit_code}" -eq 0 ]; then
        echo "   ✅ npm: all versions resolve cleanly"
        debug "npm output (last 5 lines): $(echo "${output}" | tail -5)"
        return 0
    else
        echo "   ❌ npm: dependency conflict detected"
        echo "${output}"
        return 1
    fi
}

test_pom_xml() {
    local repo_dir="$1"

    local pom_file="${repo_dir}/pom.xml"
    if [ ! -f "${pom_file}" ]; then
        echo "SKIP: pom.xml not found"
        return 0
    fi

    echo "   ── Testing Maven: ${pom_file}"
    debug "mvn dependency:resolve in: ${repo_dir}"

    local output
    cd "${repo_dir}"
    output=$(mvn dependency:resolve \
        -DskipTests \
        -B \
        --fail-at-end \
        2>&1)
    local exit_code=$?
    cd - > /dev/null
    debug "mvn exit_code=${exit_code}"

    if [ "${exit_code}" -eq 0 ]; then
        echo "   ✅ mvn: all versions resolve cleanly"
        debug "mvn output (last 5 lines): $(echo "${output}" | tail -5)"
        return 0
    else
        echo "   ❌ mvn: dependency conflict detected"
        echo "${output}" | grep -A5 -iE "conflict|ERROR|FAILURE|Could not resolve"
        debug "Full mvn output:"
        debug "${output}"
        return 1
    fi
}

# ── Dockerfile tag existence check ───────────────────────────────────────────

test_dockerfile() {
    local repo_dir="$1"

    echo "   ── Testing Dockerfile base image tag existence"

    local dockerfiles
    dockerfiles=$(find "${repo_dir}" -name "Dockerfile*" \
        -not -path "*/node_modules/*" 2>/dev/null)

    if [ -z "${dockerfiles}" ]; then
        echo "SKIP: No Dockerfiles found"
        return 0
    fi

    local all_pass=true

    while IFS= read -r dockerfile; do
        echo "   Checking: ${dockerfile}"

        grep -i "^FROM " "${dockerfile}" | while read -r from_line; do
            local image_ref
            image_ref=$(echo "${from_line}" | awk '{print $2}')

            if echo "${image_ref}" | grep -q '\$'; then
                echo "      SKIP (build-arg): ${image_ref}"
                continue
            fi

            local image=""
            local tag="latest"

            if echo "${image_ref}" | grep -q ':'; then
                image=$(echo "${image_ref}" | cut -d: -f1)
                tag=$(echo "${image_ref}" | cut -d: -f2)
            else
                image="${image_ref}"
            fi

            if echo "${image}" | grep -qE "ecr\.|dhi\.io|\.internal"; then
                echo "      SKIP (private registry): ${image_ref}"
                continue
            fi

            local docker_image="${image}"
            if ! echo "${docker_image}" | grep -q '/'; then
                docker_image="library/${docker_image}"
            fi

            echo "      Checking Docker Hub: ${docker_image}:${tag}"
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                "https://hub.docker.com/v2/repositories/${docker_image}/tags/${tag}")

            if [ "${http_code}" = "200" ]; then
                echo "      ✅ ${image_ref} — tag exists"
            else
                echo "      ❌ ${image_ref} — tag NOT found (HTTP ${http_code})"
                all_pass=false
            fi
        done
    done <<< "${dockerfiles}"

    if [ "${all_pass}" = true ]; then
        return 0
    else
        return 1
    fi
}

# ── Dockerfile OS compatibility check ────────────────────────────────────────

test_dockerfile_os_compat() {
    local repo_dir="$1"

    echo "   ── Testing Dockerfile OS compatibility"

    local dockerfiles
    dockerfiles=$(find "${repo_dir}" -name "Dockerfile*" \
        -not -path "*/node_modules/*" 2>/dev/null)

    if [ -z "${dockerfiles}" ]; then
        echo "SKIP: No Dockerfiles found"
        return 0
    fi

    local all_pass=true
    local failure_details=""

    while IFS= read -r dockerfile; do
        echo "   Checking: ${dockerfile}"

        local base_image
        base_image=$(grep -i "^FROM " "${dockerfile}" | tail -1 | awk '{print $2}')

        if echo "${base_image}" | grep -q '\$'; then
            echo "      SKIP (build-arg base): ${base_image}"
            continue
        fi

        local os_family="unknown"
        local pkg_manager="unknown"

        if echo "${base_image}" | grep -qi "alpine"; then
            os_family="alpine"
            pkg_manager="apk"
        elif echo "${base_image}" | grep -qi "slim\|debian\|ubuntu\|bullseye\|bookworm\|jammy\|focal"; then
            os_family="debian"
            pkg_manager="apt-get"
        elif echo "${base_image}" | grep -qi "centos\|rhel\|redhat\|amazonlinux\|al2"; then
            os_family="rhel"
            pkg_manager="yum"
        elif echo "${base_image}" | grep -qi "fedora"; then
            os_family="fedora"
            pkg_manager="dnf"
        fi

        echo "      Base image: ${base_image}"
        echo "      Detected OS: ${os_family}, pkg manager: ${pkg_manager}"

        if [ "${os_family}" = "unknown" ]; then
            echo "      ⚠️  Could not detect OS family — skipping OS compat check"
            continue
        fi

        local uses_apt uses_apk uses_yum uses_dnf
        uses_apt=$(grep -c "apt-get install" "${dockerfile}" 2>/dev/null || echo 0)
        uses_apk=$(grep -c "apk add" "${dockerfile}" 2>/dev/null || echo 0)
        uses_yum=$(grep -c "yum install" "${dockerfile}" 2>/dev/null || echo 0)
        uses_dnf=$(grep -c "dnf install" "${dockerfile}" 2>/dev/null || echo 0)

        if [ "${os_family}" = "alpine" ] && [ "${uses_apt}" -gt 0 ]; then
            echo "      ❌ apt-get used on Alpine base — should use apk"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: apt-get used on Alpine (${base_image}). Use 'apk add' instead."
        fi
        if [ "${os_family}" = "alpine" ] && [ "${uses_yum}" -gt 0 ]; then
            echo "      ❌ yum used on Alpine base — should use apk"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: yum used on Alpine (${base_image}). Use 'apk add' instead."
        fi
        if [ "${os_family}" = "alpine" ] && [ "${uses_dnf}" -gt 0 ]; then
            echo "      ❌ dnf used on Alpine base — should use apk"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: dnf used on Alpine (${base_image}). Use 'apk add' instead."
        fi
        if [ "${os_family}" = "debian" ] && [ "${uses_apk}" -gt 0 ]; then
            echo "      ❌ apk used on Debian/Ubuntu base — should use apt-get"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: apk used on Debian (${base_image}). Use 'apt-get install' instead."
        fi
        if [ "${os_family}" = "debian" ] && [ "${uses_yum}" -gt 0 ]; then
            echo "      ❌ yum used on Debian/Ubuntu base — should use apt-get"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: yum used on Debian (${base_image}). Use 'apt-get install' instead."
        fi
        if [ "${os_family}" = "rhel" ] && [ "${uses_apt}" -gt 0 ]; then
            echo "      ❌ apt-get used on RHEL/CentOS base — should use yum"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: apt-get used on RHEL (${base_image}). Use 'yum install' instead."
        fi
        if [ "${os_family}" = "rhel" ] && [ "${uses_apk}" -gt 0 ]; then
            echo "      ❌ apk used on RHEL/CentOS base — should use yum"
            all_pass=false
            failure_details="${failure_details}\n${dockerfile}: apk used on RHEL (${base_image}). Use 'yum install' instead."
        fi

        local install_lines
        install_lines=$(sed -n '/^RUN /,/[^\\]$/p' "${dockerfile}" \
            | tr '\\\n' ' ' \
            | grep -oE "(apt-get install|apk add|yum install|dnf install)[^&;|]*" \
            | sed 's/apt-get install//;s/apk add//;s/yum install//;s/dnf install//' \
            | sed 's/--no-cache//g;s/--no-install-recommends//g;s/-y//g;s/-qq//g;s/-q//g;s/--update//g' \
            | tr ' ' '\n' \
            | grep -v '^$' \
            | grep -v '^-' \
            | sort -u)

        if [ -z "${install_lines}" ]; then
            echo "      No package install commands found — skipping package name check"
            continue
        fi

        echo "      Packages found:"
        echo "${install_lines}" | sed 's/^/         /'

        while IFS= read -r pkg; do
            [ -z "${pkg}" ] && continue

            if [ "${os_family}" = "alpine" ]; then
                case "${pkg}" in
                    build-essential)
                        echo "      ❌ ${pkg} → use 'build-base' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'build-base'."
                        ;;
                    libpq-dev)
                        echo "      ❌ ${pkg} → use 'postgresql-dev' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'postgresql-dev'."
                        ;;
                    libssl-dev)
                        echo "      ❌ ${pkg} → use 'openssl-dev' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'openssl-dev'."
                        ;;
                    default-libmysqlclient-dev)
                        echo "      ❌ ${pkg} → use 'mariadb-dev' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'mariadb-dev'."
                        ;;
                    libxml2-dev)
                        echo "      ❌ ${pkg} → use 'libxml2-dev' on Alpine (same name, but needs 'apk add')"
                        ;;
                    libcurl4-openssl-dev)                        echo "      ❌ ${pkg} → use 'curl-dev' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'curl-dev'."
                        ;;
                    libjpeg-dev)
                        echo "      ❌ ${pkg} → use 'jpeg-dev' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'jpeg-dev'."
                        ;;
                    zlib1g-dev)
                        echo "      ❌ ${pkg} → use 'zlib-dev' on Alpine"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Alpine. Use 'zlib-dev'."
                        ;;
                    libffi-dev)
                        echo "      ✅ ${pkg} — available on Alpine"
                        ;;
                    *)
                        echo "      ℹ️  ${pkg} — not in known mismatch list"
                        ;;
                esac
            fi

            if [ "${os_family}" = "debian" ]; then
                case "${pkg}" in
                    build-base)
                        echo "      ❌ ${pkg} → use 'build-essential' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'build-essential'."
                        ;;
                    postgresql-dev)
                        echo "      ❌ ${pkg} → use 'libpq-dev' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'libpq-dev'."
                        ;;
                    openssl-dev)
                        echo "      ❌ ${pkg} → use 'libssl-dev' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'libssl-dev'."
                        ;;
                    mariadb-dev)
                        echo "      ❌ ${pkg} → use 'default-libmysqlclient-dev' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'default-libmysqlclient-dev'."
                        ;;
                    curl-dev)
                        echo "      ❌ ${pkg} → use 'libcurl4-openssl-dev' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'libcurl4-openssl-dev'."
                        ;;
                    jpeg-dev)
                        echo "      ❌ ${pkg} → use 'libjpeg-dev' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'libjpeg-dev'."
                        ;;
                    zlib-dev)
                        echo "      ❌ ${pkg} → use 'zlib1g-dev' on Debian"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on Debian. Use 'zlib1g-dev'."
                        ;;
                    *)
                        echo "      ℹ️  ${pkg} — not in known mismatch list"
                        ;;
                esac
            fi

            if [ "${os_family}" = "rhel" ]; then
                case "${pkg}" in
                    build-essential|build-base)
                        echo "      ❌ ${pkg} → use 'groupinstall Development Tools' or 'gcc make' on RHEL"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on RHEL. Use 'gcc make' or 'groupinstall Development Tools'."
                        ;;
                    libpq-dev|postgresql-dev)
                        echo "      ❌ ${pkg} → use 'postgresql-devel' on RHEL"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on RHEL. Use 'postgresql-devel'."
                        ;;
                    libssl-dev|openssl-dev)
                        echo "      ❌ ${pkg} → use 'openssl-devel' on RHEL"
                        all_pass=false
                        failure_details="${failure_details}\n${dockerfile}: '${pkg}' not on RHEL. Use 'openssl-devel'."
                        ;;
                    *)
                        echo "      ℹ️  ${pkg} — not in known mismatch list"
                        ;;
                esac
            fi

        done <<< "${install_lines}"

    done <<< "${dockerfiles}"

    if [ "${all_pass}" = true ]; then
        echo "   ✅ Dockerfile OS compatibility: no mismatches found"
        return 0
    else
        echo "   ❌ Dockerfile OS compatibility: mismatches detected"
        echo -e "${failure_details}"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DETECT WHICH RESOLVERS TO RUN
# ─────────────────────────────────────────────────────────────────────────────

determine_resolvers() {
    local changed_files="$1"
    local resolvers=""

    if echo "${changed_files}" | grep -q "requirements.*\.txt"; then
        resolvers="${resolvers} pip"
    fi
    if echo "${changed_files}" | grep -q "package\.json"; then
        resolvers="${resolvers} npm"
    fi
    if echo "${changed_files}" | grep -q "pom\.xml"; then
        resolvers="${resolvers} maven"
    fi
    if echo "${changed_files}" | grep -qi "dockerfile"; then
        resolvers="${resolvers} dockerfile"
    fi

    echo "${resolvers}" | xargs
}

# ─────────────────────────────────────────────────────────────────────────────
# RUN RESOLVERS
# ─────────────────────────────────────────────────────────────────────────────

run_resolvers() {
    local work_dir="$1"
    local resolvers="$2"

    RESOLVER_ALL_PASSED=true
    RESOLVER_RESULT_DETAILS=""
    RESOLVER_FAILED_NAME=""
    RESOLVER_FAILURE_OUTPUT=""

    for resolver in ${resolvers}; do
        local test_output=""
        local test_exit=0

        case "${resolver}" in
            pip)
                test_output=$(test_requirements_txt "${work_dir}" 2>&1)
                test_exit=$?
                ;;
            npm)
                test_output=$(test_package_json "${work_dir}" 2>&1)
                test_exit=$?
                ;;
            maven)
                test_output=$(test_pom_xml "${work_dir}" 2>&1)
                test_exit=$?
                ;;
            dockerfile)
                test_output=$(test_dockerfile "${work_dir}" 2>&1)
                test_exit=$?

                if [ "${test_exit}" -eq 0 ]; then
                    local os_output
                    os_output=$(test_dockerfile_os_compat "${work_dir}" 2>&1)
                    local os_exit=$?
                    test_output="${test_output}\n${os_output}"
                    if [ "${os_exit}" -ne 0 ]; then
                        test_exit=1
                    fi
                fi
                ;;
        esac

        echo "${test_output}"

        if [ "${test_exit}" -ne 0 ]; then
            RESOLVER_ALL_PASSED=false
            RESOLVER_FAILED_NAME="${resolver}"
            RESOLVER_FAILURE_OUTPUT=$(echo "${test_output}" | tail -30)
            RESOLVER_RESULT_DETAILS="${RESOLVER_RESULT_DETAILS}\n- ❌ **${resolver}**: FAILED"
        else
            RESOLVER_RESULT_DETAILS="${RESOLVER_RESULT_DETAILS}\n- ✅ **${resolver}**: PASSED"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " Compatibility Test — Rebase + Resolve + Automerge"
    echo " $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════════════════════"

    local total_tested=0
    local total_patch_merged=0
    local total_failed=0
    local total_rebase_conflict=0

    for repo in "${REPOS[@]}"; do
        local encoded_path
        encoded_path=$(url_encode "${repo}")

        echo ""
        echo "══ Repo: ${repo}"
        echo ""

        # ── Step 1: Fetch patch MRs targeting our base branch ────────
        local patch_mrs
        patch_mrs=$(gitlab_get \
            "${GITLAB_API}/projects/${encoded_path}/merge_requests?state=opened&labels=patch&target_branch=${BASE_BRANCH}&per_page=100")
        debug "patch_mrs count: $(echo "${patch_mrs:-[]}" | jq 'length')"

        local mrs_json
        mrs_json=$(echo "${patch_mrs:-[]}" | jq 'if type == "array" then . else [] end')
        debug "MR count: $(echo "${mrs_json}" | jq 'length')"

        if [ -z "${mrs_json}" ] || [ "${mrs_json}" = "[]" ]; then
            echo "   No open patch MRs found. Skipping."
            continue
        fi

        # ── Step 2: Filter out tested, sort oldest-first ─────────────
        local sorted_mrs
        sorted_mrs=$(echo "${mrs_json}" \
            | jq -c '
                [.[] | select(
                    (.labels | index("compatibility-test-success") | not) and
                    (.labels | index("compatibility-test-failed") | not)
                )]
                | sort_by(.created_at)')

        local mr_count
        mr_count=$(echo "${sorted_mrs}" | jq 'length')

        local patch_count
        patch_count=$(echo "${sorted_mrs}" | jq '[.[] | select(.labels | index("patch"))] | length')

        echo "   Found ${mr_count} untested patch MR(s)"
        echo "   Processing order: oldest-first"

        if [ "${mr_count}" -eq 0 ]; then
            continue
        fi

        # ── Step 3: Process each MR sequentially ─────────────────────
        # IMPORTANT: use process substitution (< <(...)) instead of pipe
        # so that variable updates (counters) survive the loop.
        while read -r mr; do
            local mr_iid mr_title source_branch mr_labels
            mr_iid=$(echo "${mr}" | jq -r '.iid')
            mr_title=$(echo "${mr}" | jq -r '.title')
            source_branch=$(echo "${mr}" | jq -r '.source_branch')
            mr_labels=$(echo "${mr}" | jq -r '.labels | join(",")')

            # Renovate labels are plain 'patch' / 'minor' per renovate-config.js ecosystemGroup()
            # Dockerfile MRs also carry 'dockerfile' label in addition to patch/minor/major
            local mr_type="patch"

            local is_dockerfile_mr="false"
            if echo "${mr_labels}" | grep -qE "(^|,)dockerfile(,|$)"; then
                is_dockerfile_mr="true"
            fi

            # Extract project_id for structured log lines
            local project_id
            project_id=$(echo "${mr}" | jq -r '.project_id')

            echo ""
            echo "   ┌─────────────────────────────────────────────────────"
            echo "   │ MR !${mr_iid}: ${mr_title}"
            echo "   │ Branch: ${source_branch}"
            echo "   │ Type: ${mr_type} | Dockerfile: ${is_dockerfile_mr}"
            echo "   │ Project ID: ${project_id}"
            echo "   │ Labels: ${mr_labels}"
            echo "   └─────────────────────────────────────────────────────"
            debug "Full MR JSON: ${mr}"

            local work_dir="/tmp/compat-test/${mr_iid}"
            rm -rf "${work_dir}"
            mkdir -p "${work_dir}"

            # ── Step 4a: Rebase onto current base branch ─────────────
            echo ""
            echo "   ── REBASE PHASE"

            rebase_mr_branch "${repo}" "${source_branch}" "${work_dir}"
            local rebase_result=$?

            if [ "${rebase_result}" -eq 1 ]; then
                total_rebase_conflict=$((total_rebase_conflict + 1))

                local conflict_note="❌ **Rebase Conflict**\n\n**MR type:** ${mr_type}\n\nThis MR could not be rebased onto \`${BASE_BRANCH}\`.\n\nAnother MR was merged before this one, and the changes conflict. Please rebase manually and resolve the conflicts."

                post_mr_note "${encoded_path}" "${mr_iid}" "${conflict_note}"
                add_mr_labels "${encoded_path}" "${mr_iid}" "compatibility-test-failed" "rebase-conflict"

                # Structured log line for email stage
                echo "COMPAT_RESULT|${mr_iid}|${project_id}|fail|rebase|Rebase conflict onto ${BASE_BRANCH}"

                echo "   ⚠️  Rebase conflict — skipping to next MR"
                rm -rf "${work_dir}"
                continue

            elif [ "${rebase_result}" -eq 2 ]; then
                local push_fail_note="⚠️ **Force-Push Failed**\n\n**MR type:** ${mr_type}\n\nRebase was clean but the force-push to \`${source_branch}\` failed. This may be a permissions or protected-branch issue."

                post_mr_note "${encoded_path}" "${mr_iid}" "${push_fail_note}"
                add_mr_labels "${encoded_path}" "${mr_iid}" "compatibility-test-failed" "push-failed"

                # Structured log line for email stage
                echo "COMPAT_RESULT|${mr_iid}|${project_id}|fail|git-push|Force-push to ${source_branch} failed"

                echo "   ⚠️  Force-push failed — skipping to next MR"
                rm -rf "${work_dir}"
                continue
            fi

            # ── Step 4b: Get changed files and determine resolvers ───
            echo ""
            echo "   ── COMPATIBILITY TEST PHASE"

            local changed_files
            changed_files=$(get_mr_changed_files "${encoded_path}" "${mr_iid}")
            echo "   Changed files:"
            echo "${changed_files}" | sed 's/^/      /'

            local resolvers
            resolvers=$(determine_resolvers "${changed_files}")

            if [ -z "${resolvers}" ]; then
                echo "   ⚠️  No dependency manifests changed — skipping test"

                local skip_note="ℹ️ **Compatibility Test — Skipped**\n\n**MR type:** ${mr_type}\n\nNo dependency manifest files (requirements.txt, package.json, pom.xml, Dockerfile) were modified in this MR."

                post_mr_note "${encoded_path}" "${mr_iid}" "${skip_note}"
                add_mr_labels "${encoded_path}" "${mr_iid}" "compatibility-test-success"

                rm -rf "${work_dir}"
                continue
            fi

            echo "   Resolvers to run: ${resolvers}"

            # ── Step 4c: Run resolvers on the rebased code ───────────
            debug "Running resolvers: [${resolvers}] on work_dir: ${work_dir}"
            run_resolvers "${work_dir}" "${resolvers}"

            total_tested=$((total_tested + 1))
            debug "RESOLVER_ALL_PASSED=${RESOLVER_ALL_PASSED} RESOLVER_FAILED_NAME=${RESOLVER_FAILED_NAME}"

            # ── Structured log line for email stage ──────────────────
            if [ "${RESOLVER_ALL_PASSED}" = true ]; then
                echo "COMPAT_RESULT|${mr_iid}|${project_id}|pass|${resolvers}|"
            else
                local error_oneline
                error_oneline=$(echo "${RESOLVER_FAILURE_OUTPUT}" | head -3 | tr '\n' ' ' | cut -c1-200)
                echo "COMPAT_RESULT|${mr_iid}|${project_id}|fail|${RESOLVER_FAILED_NAME}|${error_oneline}"
                debug "Full failure output:"
                debug "${RESOLVER_FAILURE_OUTPUT}"
            fi

            # ── Step 4d: Act on results ──────────────────────────────

            if [ "${RESOLVER_ALL_PASSED}" = true ]; then
                total_patch_merged=$((total_patch_merged + 1))

                echo ""
                echo "   ✅ All resolvers passed — automerging patch MR"

                local success_note="✅ **Dependency Compatibility Test — PASSED**\n\n**MR type:** Patch (automerge enabled)\n\n**Resolvers tested:**${RESOLVER_RESULT_DETAILS}\n\nAll dependency versions resolve cleanly after rebase onto \`${BASE_BRANCH}\`.\n\nAutomerging."

                post_mr_note "${encoded_path}" "${mr_iid}" "${success_note}"
                add_mr_labels "${encoded_path}" "${mr_iid}" "compatibility-test-success"

                echo "   Merging MR !${mr_iid}..."
                local merge_result
                merge_result=$(automerge_mr "${encoded_path}" "${mr_iid}" 2>&1)
                debug "Merge API response: ${merge_result}"

                if echo "${merge_result}" | jq -e '.state == "merged"' > /dev/null 2>&1; then
                    echo "   ✅ MR !${mr_iid} merged successfully"
                    post_mr_note "${encoded_path}" "${mr_iid}" \
                        "🤖 Automerged by Jenkins after passing compatibility test.\n\nThe next MR in the queue will be rebased onto the updated \`${BASE_BRANCH}\` before testing."

                    echo ""
                    echo "   ── Base branch ${BASE_BRANCH} updated — next MR will rebase on top"
                else
                    local merge_status
                    merge_status=$(echo "${merge_result}" | jq -r '.merge_error // .message // "unknown"')

                    post_mr_note "${encoded_path}" "${mr_iid}" \
                        "⚠️ **Automerge attempted but GitLab returned:** ${merge_status}\n\nThe compatibility test passed, but the merge could not be completed automatically. Please merge manually."

                    echo "   ⚠️  Merge failed: ${merge_status}"
                fi

            else
                # ── FAILED (both patch and minor) ────────────────────
                total_failed=$((total_failed + 1))

                echo ""
                echo "   ❌ Resolver '${RESOLVER_FAILED_NAME}' failed"

                local fail_note="❌ **Dependency Compatibility Test — FAILED**\n\n**MR type:** ${mr_type}\n**Failed resolver:** ${RESOLVER_FAILED_NAME}\n\n**Resolvers tested:**${RESOLVER_RESULT_DETAILS}\n\n**Error output (last 30 lines):**\n\`\`\`\n${RESOLVER_FAILURE_OUTPUT}\n\`\`\`\n\nThis MR has dependency conflicts that must be resolved before merging."

                post_mr_note "${encoded_path}" "${mr_iid}" "${fail_note}"
                add_mr_labels "${encoded_path}" "${mr_iid}" "compatibility-test-failed"
            fi

            rm -rf "${work_dir}"

        done < <(echo "${sorted_mrs}" | jq -c '.[]')

    done

    # ── Print structured summary for email stage to parse ─────────────
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " COMPATIBILITY TEST SUMMARY"
    echo "COMPAT_TESTED=${total_tested}"
    echo "COMPAT_PASSED=${total_patch_merged}"
    echo "COMPAT_FAILED=${total_failed}"
    echo "COMPAT_AUTOMERGED=${total_patch_merged}"
    echo "COMPAT_REBASE_CONFLICTS=${total_rebase_conflict}"
    echo "═══════════════════════════════════════════════════════════════"
}

main "$@"
