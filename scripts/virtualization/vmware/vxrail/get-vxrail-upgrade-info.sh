#!/usr/bin/env bash
# Synopsis: Shows if a VxRail cluster has an external or embedded vCenter, and its component versions, before an upgrade.
# Mode: Read-only
# Network: none (local database on VxRail Manager)
# Tested on: not yet run on a real system
# Last verified: not yet
# Usage: ./get-vxrail-upgrade-info.sh [-h] [-n] [-f <file>]
# Exit codes: 0 = done, 2 = manual check (vCenter type unknown, or psql not found), 3 = a database query failed

set -euo pipefail

PROPERTIES_FILE="/var/lib/vmware-marvin/runtime.properties"
USE_COLOR=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h] [-n] [-f <file>]

Run on VxRail Manager as root before a VxRail upgrade. Read-only.

1. External or embedded vCenter, from data.joinExternalVC in the runtime properties file
   (1 or true = external, 0 or blank = embedded).
   An external vCenter must be compatible with the target VxRail version, and if it is not,
   it must be upgraded BEFORE VxRail. An embedded vCenter is upgraded with the VxRail
   composite package.
2. Versions of the VxRail components (table virtual_appliance) and the appliances
   (table appliance), from the local VxRail Manager database (psql).

Options:
  -f <file>  runtime properties file (default: /var/lib/vmware-marvin/runtime.properties)
  -n         no colours (also off when the output is not a terminal)
  -h         show this help

Exit codes: 0 = done, 2 = manual check (vCenter type unknown, or psql not found),
            3 = a database query failed
EOF
}

while getopts ":hnf:" opt; do
    case "$opt" in
        h) usage; exit 0 ;;
        n) USE_COLOR=0 ;;
        f) PROPERTIES_FILE="$OPTARG" ;;
        :) echo "Option -$OPTARG needs a value." >&2; usage >&2; exit 3 ;;
        *) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 3 ;;
    esac
done
shift $((OPTIND - 1))

RED=''
YELLOW=''
GREEN=''
BOLD=''
RESET=''
if [ "$USE_COLOR" -eq 1 ] && [ -t 1 ]; then
    RED=$'\033[0;31m'
    YELLOW=$'\033[1;33m'
    GREEN=$'\033[0;32m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
fi

say() {
    # $1 = colour, $2 = text
    printf '%s%s%s\n' "$1" "$2" "$RESET"
}

rule() {
    printf '%s\n' "============================================================="
}

check_vcenter() {
    # Returns 0 when the vCenter type is known, 2 when it needs a manual check
    local raw value
    rule
    if [ ! -f "$PROPERTIES_FILE" ] || [ ! -r "$PROPERTIES_FILE" ]; then
        say "$YELLOW" "Cannot read $PROPERTIES_FILE."
        say "$YELLOW" "The vCenter type (external or embedded) is unknown: check it manually before the upgrade."
        rule
        return 2
    fi

    # The key is data.joinExternalVC on VxRail Manager; joinExternalVC alone is accepted too
    raw=$(grep -E '^[[:space:]]*(data\.)?joinExternalVC[[:space:]]*[=:]' "$PROPERTIES_FILE" | tail -n 1 | tr -d '\r' || true)
    if [ -z "$raw" ]; then
        say "$YELLOW" "data.joinExternalVC was not found in $PROPERTIES_FILE."
        say "$YELLOW" "The vCenter type (external or embedded) is unknown: check it manually before the upgrade."
        rule
        return 2
    fi

    printf '%s\n' "$raw"
    value=${raw#*[=:]}
    value=$(printf '%s' "$value" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|true)
            say "$RED" "EXTERNAL vCenter: check that its version is compatible with the target VxRail version."
            say "$YELLOW" "If it is not compatible, the vCenter must be upgraded BEFORE VxRail is upgraded."
            ;;
        ''|0|false)
            # 0 or blank = embedded (internal) vCenter
            say "$GREEN" "EMBEDDED (internal) vCenter: it is upgraded with the VxRail composite package."
            ;;
        *)
            say "$YELLOW" "Unexpected value '$value': the vCenter type is unknown, check it manually before the upgrade."
            rule
            return 2
            ;;
    esac
    rule
    return 0
}

run_query() {
    # $1 = title, $2 = SQL. Returns 3 when the query fails (psql prints the error).
    local title="$1" sql="$2"
    printf '\n%s%s%s\n' "$BOLD" "$title" "$RESET"
    # -w: never prompt for a password, fail instead
    if ! psql -U postgres -w -P pager=off mysticmanager -c "$sql"; then
        say "$RED" "ERROR: the query failed (see the psql error above). Run the script as root on VxRail Manager."
        return 3
    fi
    return 0
}

main() {
    local rc=0 vc_rc=0 db_rc=0

    printf '%sVxRail upgrade information%s - %s - %s\n\n' "$BOLD" "$RESET" \
        "$(hostname 2>/dev/null || uname -n)" "$(date '+%Y-%m-%d %H:%M')"

    check_vcenter || vc_rc=$?
    rc=$vc_rc

    if ! command -v psql > /dev/null 2>&1; then
        printf '\n'
        say "$YELLOW" "psql was not found on this host, so the database part is skipped."
        exit 2
    fi

    run_query "VxRail components (virtual_appliance)" \
        "select id,component,component_id,ip,current_version,install_time,upgrade_version,upgrade_status from virtual_appliance order by id" \
        || db_rc=3
    run_query "Appliances (appliance)" \
        "select id,psnt,cluster_id,model,health,missing,generation from appliance" \
        || db_rc=3

    if [ "$db_rc" -ne 0 ]; then
        rc=$db_rc
    fi
    if [ "$vc_rc" -ne 0 ]; then
        printf '\n'
        say "$YELLOW" "MANUAL CHECK: the vCenter type is unknown (see above)."
    fi
    exit "$rc"
}

main "$@"
