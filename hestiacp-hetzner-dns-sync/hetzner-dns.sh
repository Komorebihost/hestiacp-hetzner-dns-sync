#!/bin/bash
# =============================================================================
# HestiaCP → Hetzner DNS  –  Engine  v2.0.0
# /usr/local/hestia/plugins/hetzner-dns/hetzner-dns.sh
#
# Compatible: Ubuntu 20/22/24, Debian 11/12, Rocky/AlmaLinux 8/9
#
# Hetzner DNS API (dns.hetzner.com/api/v1) – RRset based
# An RRset groups all records with the same name+type into one object.
#
# Endpoints:
#   GET    /zones?name=DOMAIN
#   POST   /zones
#   DELETE /zones/{zone_id}
#   GET    /zones/{zone_id}/records
#   POST   /zones/{zone_id}/rrsets
#   PUT    /zones/{zone_id}/rrsets/{name}/{type}
#   DELETE /zones/{zone_id}/rrsets/{name}/{type}
#
# Cache files:
#   mapping/zones.json         {"domain": {"id": "...", "token": "..."}}
#   mapping/rrsets_ZONE.json   {"name/TYPE": "hestia_domain_owner"}
#
# Subdomain logic:
#   sub.example.com → records go into parent zone example.com
#   @ becomes "sub", mail becomes "mail.sub" in the parent zone
# =============================================================================

PLUGIN_DIR="/usr/local/hestia/plugins/hetzner-dns"
CONFIG="$PLUGIN_DIR/config.conf"
MAPPING_DIR="$PLUGIN_DIR/mapping"
LOG="$PLUGIN_DIR/hetzner-dns.log"
HESTIA_USER_DIR="/usr/local/hestia/data/users"
API="https://api.hetzner.cloud/v1"

[ -f "$CONFIG" ] || { echo "[ERROR] Config not found: $CONFIG" >&2; exit 1; }
source "$CONFIG"
[ -z "${HETZNER_API_TOKENS:-}" ] && HETZNER_API_TOKENS="${HETZNER_API_TOKEN:-}"
[ -n "$HETZNER_API_TOKENS" ] || { echo "[ERROR] HETZNER_API_TOKENS not set" >&2; exit 1; }
mkdir -p "$MAPPING_DIR"

DEFAULT_TTL="${DEFAULT_TTL:-86400}"

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >> "$LOG"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERR " "$@"; }

# ── API ───────────────────────────────────────────────────────────────────────
_api() {
    local token="$1" method="$2" endpoint="$3" body="${4:-}"
    local args=(-s -X "$method"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        --max-time 30 --retry 2 --retry-delay 2)
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}" "${API}${endpoint}"
}

# ── Zone cache ────────────────────────────────────────────────────────────────
# {"domain": {"id": "zone_id", "token": "api_token"}}
zone_get_id() {
    local domain="$1" cache="$MAPPING_DIR/zones.json"
    if [ -f "$cache" ]; then
        local v; v=$(jq -r --arg d "$domain" '.[$d].id // empty' "$cache" 2>/dev/null)
        [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    local token zone_id resp
    for token in $HETZNER_API_TOKENS; do
        resp=$(_api "$token" GET "/zones?name=${domain}&per_page=1")
        zone_id=$(echo "$resp" | jq -r '.zones[0].id // empty' 2>/dev/null)
        if [ -n "$zone_id" ]; then
            zone_cache_set "$domain" "$zone_id" "$token"
            echo "$zone_id"; return 0
        fi
    done
    return 1
}

zone_get_token() {
    local domain="$1" cache="$MAPPING_DIR/zones.json"
    local token; token=$(jq -r --arg d "$domain" '.[$d].token // empty' "$cache" 2>/dev/null)
    [ -n "$token" ] && { echo "$token"; return 0; }
    zone_get_id "$domain" >/dev/null || return 1
    jq -r --arg d "$domain" '.[$d].token // empty' "$cache" 2>/dev/null
}

zone_cache_set() {
    local cache="$MAPPING_DIR/zones.json"
    [ -f "$cache" ] || echo '{}' > "$cache"
    jq --arg d "$1" --arg id "$2" --arg tok "$3" \
        '.[$d]={id:$id,token:$tok}' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

zone_cache_del() {
    local cache="$MAPPING_DIR/zones.json"
    [ -f "$cache" ] || return 0
    jq --arg d "$1" 'del(.[$d])' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

zone_exists_on_hetzner() {
    local domain="$1" zone_id="$2" token="$3"
    local found; found=$(_api "$token" GET "/zones/${zone_id}" \
        | jq -r '.zone.name // empty' 2>/dev/null)
    [ "$found" = "$domain" ]
}

# ── RRset ownership cache ─────────────────────────────────────────────────────
# {"name/TYPE": "hestia_domain_owner"}
rrset_cache_file() { echo "$MAPPING_DIR/rrsets_${1//./_}.json"; }

rrset_cache_set() {
    local cache; cache=$(rrset_cache_file "$1")
    [ -f "$cache" ] || echo '{}' > "$cache"
    jq --arg k "$2" --arg o "$3" '.[$k]=$o' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

rrset_cache_owned() {
    local cache; cache=$(rrset_cache_file "$1")
    [ -f "$cache" ] || return 0
    jq -r --arg o "$2" 'to_entries[] | select(.value==$o) | .key' "$cache" 2>/dev/null
}

rrset_cache_purge() {
    local cache; cache=$(rrset_cache_file "$1")
    [ -f "$cache" ] || return 0
    jq --arg o "$2" 'with_entries(select(.value!=$o))' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

# ── Parse a single HestiaCP DNS conf line ────────────────────────────────────
parse_line() {
    p_record=$(   echo "$1" | sed -n "s/.*RECORD='\([^']*\)'.*/\1/p")
    p_ttl=$(      echo "$1" | sed -n "s/.*TTL='\([^']*\)'.*/\1/p")
    p_type=$(     echo "$1" | sed -n "s/.*TYPE='\([^']*\)'.*/\1/p")
    p_priority=$( echo "$1" | sed -n "s/.*PRIORITY='\([^']*\)'.*/\1/p")
    p_value=$(    echo "$1" | sed -n "s/.*VALUE='\([^']*\)'.*/\1/p")
    p_suspended=$(echo "$1" | sed -n "s/.*SUSPENDED='\([^']*\)'.*/\1/p")
}

# ── Normalize record value for Hetzner ───────────────────────────────────────
build_hetzner_value() {
    local type="$1" val="$2" prio="$3"
    case "$type" in
        MX)
            [[ "$val" == *. ]] || val="${val}."
            [ -n "$prio" ] && val="${prio} ${val}"
            ;;
        NS|CNAME|PTR)
            [[ "$val" == *. ]] || val="${val}."
            ;;
        SRV)
            [[ "$val" == *. ]] || val="${val}."
            [ -n "$prio" ] && val="${prio} ${val}"
            ;;
        TXT)
            [[ "$val" == '"'* ]] || val="\"${val}\""
            ;;
    esac
    echo "$val"
}

# ── Build record name for Hetzner (apex = @) ─────────────────────────────────
build_record_name() {
    local raw="$1" domain="$2"
    local name="${raw%.}"
    name="${name%.${domain}}"
    [ "$name" = "$domain" ] && name=""
    echo "${name:-@}"
}

# ── Build full name for subdomain records ─────────────────────────────────────
# e.g. zone=example.com  hestia=sub.example.com  record=@    → "sub"
#      zone=example.com  hestia=sub.example.com  record=mail → "mail.sub"
build_full_name() {
    local rec_name="$1" hestia_domain="$2" zone_domain="$3"
    [ "$hestia_domain" = "$zone_domain" ] && { echo "$rec_name"; return; }
    local prefix="${hestia_domain%.$zone_domain}"
    [ "$rec_name" = "@" ] && echo "$prefix" || echo "${rec_name}.${prefix}"
}

# ── Find HestiaCP user owning a domain ───────────────────────────────────────
find_user() {
    local domain="$1" hint="${2:-}"
    if [ -n "$hint" ] && [ -f "$HESTIA_USER_DIR/$hint/dns/$domain.conf" ]; then
        echo "$hint"; return 0
    fi
    for conf in "$HESTIA_USER_DIR"/*/dns/"$domain.conf"; do
        [ -f "$conf" ] && basename "$(dirname "$(dirname "$conf")")" && return 0
    done
    return 1
}

# ── Delete a single RRset from Hetzner ───────────────────────────────────────
delete_rrset() {
    local token="$1" zone_id="$2" name="$3" type="$4"
    local resp err
    resp=$(_api "$token" DELETE "/zones/${zone_id}/rrsets/${name}/${type}")
    err=$(echo "$resp" | jq -r '.error.message // empty' 2>/dev/null)
    [ -n "$err" ] \
        && log_warn "  delete rrset $name/$type: $err" \
        || log_info "  -rrset $name/$type"
}

# ── Sync all records of a hestia_domain into its Hetzner zone ────────────────
# Strategy: delete all rrsets owned by this hestia_domain, then
# push fresh rrsets grouped by name+type from the conf file.
sync_domain() {
    local hestia_domain="$1" zone_domain="$2" zone_id="$3" user_hint="${4:-}"

    local user; user=$(find_user "$hestia_domain" "$user_hint") || {
        log_error "User not found for $hestia_domain"; return 1
    }
    local conf="$HESTIA_USER_DIR/$user/dns/$hestia_domain.conf"
    [ -f "$conf" ] || { log_warn "Conf not found: $conf"; return 0; }

    local token; token=$(zone_get_token "$zone_domain") || return 1
    log_info "sync_domain: $hestia_domain → zone $zone_domain (id=$zone_id)"

    # 1. Delete existing rrsets owned by this hestia_domain
    local old_key
    while IFS= read -r old_key; do
        delete_rrset "$token" "$zone_id" "${old_key%/*}" "${old_key##*/}"
    done < <(rrset_cache_owned "$zone_domain" "$hestia_domain")
    rrset_cache_purge "$zone_domain" "$hestia_domain"

    # 2. Build a temp file with all records: name\ttype\tttl\tvalue
    local tmpfile; tmpfile=$(mktemp)

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        parse_line "$line"
        [ -z "$p_type" ] || [ "$p_type" = "SOA" ] && continue
        [ "$p_suspended" = "yes" ] && continue

        # Skip apex NS — managed by Hetzner automatically
        if [ "$p_type" = "NS" ]; then
            local rn; rn=$(build_record_name "$p_record" "$hestia_domain")
            [ "$rn" = "@" ] && continue
        fi

        local rec_name full_name value
        rec_name=$(build_record_name "$p_record" "$hestia_domain")
        full_name=$(build_full_name "$rec_name" "$hestia_domain" "$zone_domain")
        value=$(build_hetzner_value "$p_type" "$p_value" "$p_priority")
        printf '%s\t%s\t%s\t%s\n' "$full_name" "$p_type" "${p_ttl:-$DEFAULT_TTL}" "$value" \
            >> "$tmpfile"
    done < "$conf"

    # 3. Group by name+type and POST each rrset to Hetzner
    # Strategy: extract unique name+type pairs, then for each one collect
    # all values from tmpfile. Avoids the newline-in-pipe splitting bug.
    local pushed=0 failed=0
    local keys_file; keys_file=$(mktemp)
    awk -F'\t' '{print $1"\t"$2}' "$tmpfile" | sort -u > "$keys_file"

    while IFS=$'\t' read -r name type; do
        [ -z "$name" ] || [ -z "$type" ] && continue

        # Build records JSON array and get TTL from tmpfile for this name+type
        local records_json ttl count
        records_json=$(awk -F'\t' -v n="$name" -v t="$type" '
            BEGIN { c=0; printf "[" }
            $1==n && $2==t {
                v=$4; gsub(/"/, "\\\"", v)
                printf "%s{\"value\":\"%s\"}", (c>0?",":""), v
                c++
            }
            END { printf "]" }
        ' "$tmpfile")
        ttl=$(awk -F'\t' -v n="$name" -v t="$type" \
            '$1==n && $2==t {print $3; exit}' "$tmpfile")
        count=$(awk -F'\t' -v n="$name" -v t="$type" \
            '$1==n && $2==t {c++} END{print c+0}' "$tmpfile")

        local body
        body=$(jq -n \
            --arg n "$name" --arg t "$type" \
            --arg l "${ttl:-$DEFAULT_TTL}" \
            --argjson r "$records_json" \
            '{name:$n,type:$t,ttl:($l|tonumber),records:$r}')

        local resp err rrset_id
        resp=$(_api "$token" POST "/zones/${zone_id}/rrsets" "$body")
        rrset_id=$(echo "$resp" | jq -r '.rrset.id // empty' 2>/dev/null)

        if [ -n "$rrset_id" ]; then
            rrset_cache_set "$zone_domain" "${name}/${type}" "$hestia_domain"
            log_info "  +rrset $name/$type ($count record/s)"
            ((pushed++))
        else
            err=$(echo "$resp" | jq -r '.error.message // .error.code // "?"' 2>/dev/null)
            if [[ "$err" == *"already exist"* ]]; then
                # RRset exists — delete it first, then recreate
                _api "$token" DELETE "/zones/${zone_id}/rrsets/${name}/${type}" >/dev/null
                resp=$(_api "$token" POST "/zones/${zone_id}/rrsets" "$body")
                rrset_id=$(echo "$resp" | jq -r '.rrset.id // empty' 2>/dev/null)
                if [ -n "$rrset_id" ]; then
                    rrset_cache_set "$zone_domain" "${name}/${type}" "$hestia_domain"
                    log_info "  ~rrset $name/$type (replaced, $count record/s)"
                    ((pushed++))
                else
                    local err2; err2=$(echo "$resp" | jq -r '.error.message // "?"' 2>/dev/null)
                    log_error "  ~rrset $name/$type replace FAILED: $err2"
                    ((failed++))
                fi
            else
                log_error "  +rrset $name/$type FAILED: $err"
                ((failed++))
            fi
        fi
    done < "$keys_file"

    rm -f "$tmpfile" "$keys_file"
    log_info "sync done: $hestia_domain | +$pushed ERR=$failed"
}

# ── action_sync ───────────────────────────────────────────────────────────────
action_sync() {
    local hestia_domain="$1" user_hint="${2:-}"
    log_info "=== sync: $hestia_domain (user=${user_hint:-?}) ==="

    # Subdomain? Check if parent zone exists on Hetzner
    local parent="${hestia_domain#*.}"
    if [[ "$hestia_domain" == *.*.* ]]; then
        local pid; pid=$(zone_get_id "$parent") || true
        if [ -n "$pid" ]; then
            local ptoken; ptoken=$(zone_get_token "$parent")
            if zone_exists_on_hetzner "$parent" "$pid" "$ptoken"; then
                log_info "$hestia_domain is subdomain → parent zone $parent (id=$pid)"
                sync_domain "$hestia_domain" "$parent" "$pid" "$user_hint"
                return $?
            fi
            log_warn "Parent zone $parent (id=$pid) gone from Hetzner → clearing cache"
            zone_cache_del "$parent"
            rm -f "$(rrset_cache_file "$parent")"
        fi
    fi

    # Get or create zone on Hetzner
    local zone_id; zone_id=$(zone_get_id "$hestia_domain") || true

    if [ -n "$zone_id" ]; then
        local token; token=$(zone_get_token "$hestia_domain")
        if ! zone_exists_on_hetzner "$hestia_domain" "$zone_id" "$token"; then
            log_warn "Zone $hestia_domain (id=$zone_id) gone from Hetzner → recreating"
            zone_cache_del "$hestia_domain"
            rm -f "$(rrset_cache_file "$hestia_domain")"
            zone_id=""
        fi
    fi

    if [ -z "$zone_id" ]; then
        # Create zone using first token
        local token; token=$(echo "$HETZNER_API_TOKENS" | awk '{print $1}')
        local body resp
        body=$(jq -n --arg n "$hestia_domain" --arg m "primary" \
            '{name:$n,mode:$m}')
        resp=$(_api "$token" POST "/zones" "$body")
        zone_id=$(echo "$resp" | jq -r '.zone.id // empty' 2>/dev/null)
        if [ -z "$zone_id" ]; then
            local err; err=$(echo "$resp" | jq -r '.error.message // "?"' 2>/dev/null)
            log_error "Failed to create zone $hestia_domain: $err"
            return 1
        fi
        log_info "Zone CREATED: $hestia_domain (id=$zone_id)"
        zone_cache_set "$hestia_domain" "$zone_id" "$token"
    else
        log_info "Zone exists: $hestia_domain (id=$zone_id)"
    fi

    sync_domain "$hestia_domain" "$hestia_domain" "$zone_id" "$user_hint"
}

# ── action_delete ─────────────────────────────────────────────────────────────
action_delete() {
    local hestia_domain="$1" user_hint="${2:-}"
    log_info "=== delete: $hestia_domain ==="

    # Subdomain: remove only its rrsets from parent zone
    local parent="${hestia_domain#*.}"
    if [[ "$hestia_domain" == *.*.* ]]; then
        local pid; pid=$(zone_get_id "$parent") || true
        if [ -n "$pid" ]; then
            local token; token=$(zone_get_token "$parent")
            log_info "$hestia_domain is subdomain → removing rrsets from $parent"
            local old_key
            while IFS= read -r old_key; do
                delete_rrset "$token" "$pid" "${old_key%/*}" "${old_key##*/}"
            done < <(rrset_cache_owned "$parent" "$hestia_domain")
            rrset_cache_purge "$parent" "$hestia_domain"
            return 0
        fi
    fi

    # Root zone: delete entire Hetzner zone
    local zone_id; zone_id=$(zone_get_id "$hestia_domain") || {
        log_warn "Zone not found on Hetzner: $hestia_domain"
        return 0
    }
    local token; token=$(zone_get_token "$hestia_domain")
    _api "$token" DELETE "/zones/${zone_id}" >/dev/null
    log_info "Zone DELETED: $hestia_domain (id=$zone_id)"
    zone_cache_del "$hestia_domain"
    rm -f "$(rrset_cache_file "$hestia_domain")"
}

# ── action_sync_all ───────────────────────────────────────────────────────────
action_sync_all() {
    local filter_user="${1:-}" users

    if [ -n "$filter_user" ]; then
        [ -d "$HESTIA_USER_DIR/$filter_user" ] || {
            echo "User not found: $filter_user"; exit 1
        }
        users="$filter_user"
    else
        users=$(ls "$HESTIA_USER_DIR" 2>/dev/null)
    fi

    local total=0 ok=0 fail=0
    for user in $users; do
        local dns_dir="$HESTIA_USER_DIR/$user/dns"
        [ -d "$dns_dir" ] || continue
        for conf in "$dns_dir"/*.conf; do
            [ -f "$conf" ] || continue
            local domain; domain=$(basename "$conf" .conf)
            ((total++))
            echo "→ $domain (user=$user)"
            action_sync "$domain" "$user" && ok=$((ok+1)) || fail=$((fail+1))
        done
    done

    echo ""
    echo "Total: $total | OK: $ok | Errors: $fail"
}

# ── action_debug ──────────────────────────────────────────────────────────────
action_debug() {
    local domain="$1"
    echo "=== DEBUG: $domain ==="

    for token in $HETZNER_API_TOKENS; do
        echo "Token: ${token:0:12}..."
        local resp
        resp=$(_api "$token" GET "/zones?name=${domain}&per_page=1")
        echo "$resp" | jq '{id:.zones[0].id,name:.zones[0].name,records:.zones[0].record_count}'
        local zid; zid=$(echo "$resp" | jq -r '.zones[0].id // empty')
        if [ -n "$zid" ]; then
            echo ""
            echo "RRsets on Hetzner (zone $zid):"
            _api "$token" GET "/zones/${zid}/rrsets" | \
                jq '.rrsets[] | {name,type,ttl,values:[.records[].value]}'
        fi
    done

    echo ""
    echo "Local cache:"
    jq --arg d "$domain" '.[$d] // "(not cached)"' "$MAPPING_DIR/zones.json" 2>/dev/null
    local rcf; rcf=$(rrset_cache_file "$domain")
    [ -f "$rcf" ] && jq '.' "$rcf" || echo "(rrset cache empty)"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    sync)     action_sync     "${2:?'Usage: $0 sync DOMAIN [USER]'}" "${3:-}" ;;
    delete)   action_delete   "${2:?'Usage: $0 delete DOMAIN [USER]'}" "${3:-}" ;;
    sync_all) action_sync_all "${2:-}" ;;
    debug)    action_debug    "${2:?'Usage: $0 debug DOMAIN'}" ;;
    *) echo "Usage: $0 {sync DOMAIN [USER]|delete DOMAIN [USER]|sync_all [USER]|debug DOMAIN}"; exit 1 ;;
esac
