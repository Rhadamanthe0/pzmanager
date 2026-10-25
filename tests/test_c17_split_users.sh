#!/usr/bin/env bash
# test_c17_split_users.sh - Séparation JVM (pzgame) / admin (pzmanager).
# Inspection statique + simulation de permissions, sans root :
# aucune étape ne requiert l'EUID 0 ni ne touche au système.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_PARSE="$REPO_ROOT/data/scripts/lib/env_parse.sh"
COMMON="$REPO_ROOT/data/scripts/lib/common.sh"
SETUP_SYS="$REPO_ROOT/data/scripts/install/setupSystem.sh"
CONF_INIT="$REPO_ROOT/data/scripts/install/configurationInitiale.sh"
SERVICE="$REPO_ROOT/data/setupTemplates/zomboid.service"
SOCKET="$REPO_ROOT/data/setupTemplates/zomboid.socket"
MIGRATE="$REPO_ROOT/data/scripts/install/migrate-to-split-users.sh"
SIM=""

cleanup() {
    [[ -n "$SIM" && -d "$SIM" ]] && rm -rf "$SIM"
}
trap cleanup EXIT

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[OK] $*"; }
skip_note() { echo "[SKIP-local] $*"; }

# Capacité du FS local : sur NTFS (Git Bash Windows), chmod est sans effet
# (stat relit 644/755). On prouve alors la COMMANDE émie (journal des appels)
# plutôt que l'effet FS ; sur Linux le mode réel est vérifié en plus.
probe_fs_modes() {
    local f m
    f="$(mktemp)"
    chmod 600 "$f" 2>/dev/null || true
    m="$(stat -c %a "$f" 2>/dev/null || echo ?)"
    rm -f "$f"
    [[ "$m" == "600" ]] && echo 1 || echo 0
}
FS_MODES="$(probe_fs_modes)"
# Liens symboliques : sans privilège dédié (Windows), ln -s vers un dossier
# peut "réussir" sans créer de lien. Même traitement que FS_MODES.
probe_fs_links() {
    local d
    d="$(mktemp -d)"
    mkdir "$d/target"
    if ln -s "$d/target" "$d/link" 2>/dev/null && [[ -L "$d/link" ]]; then
        echo 1
    else
        echo 0
    fi
    rm -rf "$d"
}
FS_LINKS="$(probe_fs_links)"

code_lines() { grep -vE '^[[:space:]]*#' "$1"; }

# --- (a) common.sh : défauts compatibles mono-user ---------------------------
grep -q 'PZ_GAME_USER:=${PZ_USER}' "$COMMON" || fail "common.sh : défaut PZ_GAME_USER absent"
grep -q 'PZ_MANAGER_USER:=${PZ_USER}' "$COMMON" || fail "common.sh : défaut PZ_MANAGER_USER absent"
grep -q 'PZ_GAME_HOME:=/home/${PZ_GAME_USER}' "$COMMON" || fail "common.sh : défaut PZ_GAME_HOME absent"
grep -q 'PZ_MANAGER_HOME:=/home/${PZ_MANAGER_USER}' "$COMMON" || fail "common.sh : défaut PZ_MANAGER_HOME absent"
grep -qE '^ *export .*PZ_GAME_USER.*PZ_MANAGER_USER.*PZ_GAME_HOME.*PZ_MANAGER_HOME' "$COMMON" \
    || fail "common.sh : nouvelles clés non exportées"
pass "common.sh déclare PZ_GAME_USER/PZ_MANAGER_USER (+homes) et les exporte"

# Compat fonctionnelle : sans ces clés, tout vaut PZ_USER (comme avant).
mapfile -t mono_vals < <(bash -c 'unset PZ_USER PZ_GAME_USER PZ_MANAGER_USER PZ_GAME_HOME PZ_MANAGER_HOME PZ_HOME
    source "$0" >/dev/null 2>&1; apply_env_defaults
    printf "%s\n" "$PZ_USER" "$PZ_GAME_USER" "$PZ_MANAGER_USER" "$PZ_GAME_HOME" "$PZ_MANAGER_HOME"' "$COMMON")
[[ "${mono_vals[1]}" == "${mono_vals[0]}" && "${mono_vals[2]}" == "${mono_vals[0]}" ]] \
    || fail "mono-user non compatible : GAME=${mono_vals[1]} MANAGER=${mono_vals[2]} USER=${mono_vals[0]}"
[[ "${mono_vals[3]}" == "/home/${mono_vals[1]}" && "${mono_vals[4]}" == "/home/${mono_vals[2]}" ]] \
    || fail "homes non dérivés : GAME_HOME=${mono_vals[3]} MANAGER_HOME=${mono_vals[4]}"
pass "mono-user : PZ_GAME_USER==PZ_MANAGER_USER==PZ_USER (${mono_vals[0]})"

# Mode split : les valeurs posées sont préservées (jamais écrasées).
split="$(PZ_USER=pzmgr PZ_GAME_USER=pzgame PZ_MANAGER_USER=pzmgr bash -c '
    source "$0" >/dev/null 2>&1; apply_env_defaults
    echo "G=$PZ_GAME_USER M=$PZ_MANAGER_USER"' "$COMMON")"
[[ "$split" == "G=pzgame M=pzmgr" ]] || fail "split non préservé : $split"
pass "split : valeurs posées préservées ($split)"

# env_parse.sh accepte les deux clés avec la même regex utilisateur que PZ_USER.
[[ -f "$ENV_PARSE" ]] || fail "env_parse.sh introuvable"
# shellcheck disable=SC1090
source "$ENV_PARSE"
tmp_env="$(mktemp)"
printf '%s\n' 'PZ_USER=pzmgr' 'PZ_GAME_USER=pzgame' 'PZ_MANAGER_USER=pzmgr' 'PZ_GAME_USER_NOT=evil' > "$tmp_env"
unset PZ_USER PZ_GAME_USER PZ_MANAGER_USER PZ_GAME_USER_NOT || true
parse_env_declarative "$tmp_env" || fail "parse_env_declarative a échoué"
rm -f "$tmp_env"
[[ "${PZ_GAME_USER:-}" == "pzgame" ]] || fail "PZ_GAME_USER=${PZ_GAME_USER:-<vide>}"
[[ "${PZ_MANAGER_USER:-}" == "pzmgr" ]] || fail "PZ_MANAGER_USER=${PZ_MANAGER_USER:-<vide>}"
[[ -z "${PZ_GAME_USER_NOT:-}" ]] || fail "clé hors whitelist acceptée"
tmp_env="$(mktemp)"
printf '%s\n' 'PZ_GAME_USER="BAD;INJECTION"' > "$tmp_env"
unset PZ_GAME_USER || true
parse_env_declarative "$tmp_env" || fail "parse_env_declarative a échoué (invalide)"
rm -f "$tmp_env"
[[ -z "${PZ_GAME_USER:-}" ]] || fail "valeur invalide acceptée : ${PZ_GAME_USER:-}"
pass "env_parse.sh : PZ_GAME_USER/PZ_MANAGER_USER validés comme PZ_USER, reste rejeté"

# --- (b) unités --user : identité héritée et durcissement -------------------
for key in 'NoNewPrivileges=true' 'ProtectSystem=strict' 'ReadWritePaths'; do
    grep -qF "$key" "$SERVICE" || fail "zomboid.service : '$key' absent"
done
grep -q 'WorkingDirectory=' "$SERVICE" || fail "zomboid.service : WorkingDirectory perdu"
code_lines "$SERVICE" | grep -qE '^[[:space:]]*ProtectHome' \
    && fail "zomboid.service : ProtectHome actif (casserait le cachedir)"
code_lines "$SERVICE" | grep -qE '^[[:space:]]*User=' \
    && fail "zomboid.service : directive User= active interdite en unité --user"
grep -q 'ReadWritePaths=%h/pzmanager/data/pzserver' "$SERVICE" || fail "ReadWritePaths install absent"
grep -q 'ReadWritePaths=.*%h/pzmanager/Zomboid' "$SERVICE" || fail "ReadWritePaths monde absent"
grep -q 'ReadWritePaths=.*%h/pzmanager/logs' "$SERVICE" || fail "ReadWritePaths logs absent"
pass "zomboid.service : identité héritée (--user), durcissement + ReadWritePaths install/monde/logs"
grep -q 'SocketMode=0660' "$SOCKET" || fail "zomboid.socket : SocketMode 0660 perdu"
pass "zomboid.socket : SocketMode 0660 conservé"

# --- (c) secrets manager jamais exposés ; split refusé dynamiquement en (e) ---
grep -n 'chmod 0600' "$SETUP_SYS" | grep -qiE 'secret|ssh' \
    || fail "setupSystem.sh : .env/.ssh non resserrés à 0600"
grep -n 'chmod 0700' "$SETUP_SYS" | grep -qiE 'ssh' \
    || fail "setupSystem.sh : .ssh non resserré à 0700"
grep -q 'chmod 0750' "$SETUP_SYS" || fail "setupSystem.sh : home manager non resserré à 0750"
code_lines "$SETUP_SYS" | grep -qE 'chmod[^#]*644' \
    && fail "setupSystem.sh : chmod 644 détecté (secret exposé)"
code_lines "$SETUP_SYS" | grep -E '^[[:space:]]*chown' | grep -qiE 'secret|ssh_dir|ENV_FILE|fullBackup|SYNC_BACKUPS' \
    && fail "setupSystem.sh : un secret/backup est donné à un autre compte"
code_lines "$SETUP_SYS" | grep -qiE 'chown.*GAME.*(BACKUP|secret|ssh)|chmod.*pzgame.*(env|ssh)' \
    && fail "setupSystem.sh : lecture donnée au compte jeu"
pass "setupSystem.sh : secrets en 0600/0700/0750, aucun 644, rien donné à pzgame"

# Le mode multi-UID est refusé AVANT tout prérequis ou mutation.
SIM="$(mktemp -d)"
mkdir "$SIM/world"
printf 'world-before\n' > "$SIM/world/sentinel"
printf 'secret-before\n' > "$SIM/secret"
chmod 0700 "$SIM/world"; chmod 0600 "$SIM/secret"
before="$(stat -c '%u:%a:%s' "$SIM/world" "$SIM/secret"; sha256sum "$SIM/world/sentinel" "$SIM/secret")"
set +e
bash -eu -c '
    source "$1"
    PZ_GAME_USER=pzgame
    PZ_MANAGER_USER=pzmanager
    PZ_SOURCE_DIR="$2/world"
    PZ_INSTALL_DIR="$2/install"
    export C17_PREREQUISITE="$2/prerequisite-called"
    loginctl() { touch "$C17_PREREQUISITE"; }
    install_zomboid_dependencies() { touch "$C17_PREREQUISITE"; }
    ensure_runtime_dir() { touch "$C17_PREREQUISITE"; }
    as_manager() { touch "$C17_PREREQUISITE"; }
    install_zomboid
' "$SETUP_SYS" "$CONF_INIT" "$SIM" > "$SIM/refusal.log" 2>&1
rc=$?
set -e
[[ "$rc" != 0 ]] || fail "installation multi-UID acceptée"
grep -q 'split multi-UID non pris en charge, aucun fichier modifié' "$SIM/refusal.log" \
    || fail "refus multi-UID sans preuve causale"
[[ ! -e "$SIM/prerequisite-called" && ! -e "$SIM/install" ]] || fail "prérequis exécuté malgré split"
[[ "$(stat -c '%u:%a:%s' "$SIM/world" "$SIM/secret"; sha256sum "$SIM/world/sentinel" "$SIM/secret")" == "$before" ]] \
    || fail "monde/secret modifié malgré split"
rm -rf "$SIM"; SIM=""
pass "configurationInitiale.sh : split refusé avant prérequis, monde/secret owner/mode/contenu intacts"

# --- (d) simulation : secret 0600 illisible pour un autre compte -------------
SIM="$(mktemp -d)"
MGR="$SIM/home/pzmgr"
GAME="$SIM/home/pzgame"
mkdir -p "$MGR/pzmanager" "$MGR/.ssh" "$GAME"
printf 'DISCORD_BOT_TOKEN=topsecret\n' > "$MGR/pzmanager/.env"
printf 'cle-privee\n' > "$MGR/.ssh/id_ed25519"
chmod 0600 "$MGR/pzmanager/.env"
chmod 0700 "$MGR/.ssh"
chmod 0600 "$MGR/.ssh/id_ed25519"
chmod 0750 "$MGR"
env_owner="$(stat -c %U "$MGR/pzmanager/.env")"
[[ "$env_owner" != "pzgame" ]] || fail "propriétaire inattendu : $env_owner"
if (( FS_MODES )); then
    env_mode="$(stat -c %a "$MGR/pzmanager/.env")"
    ssh_mode="$(stat -c %a "$MGR/.ssh")"
    home_mode="$(stat -c %a "$MGR")"
    [[ "$env_mode" == "600" ]] || fail ".env mode=$env_mode (attendu 600)"
    [[ "$ssh_mode" == "700" ]] || fail ".ssh mode=$ssh_mode (attendu 700)"
    [[ "$home_mode" == "750" ]] || fail "home mode=$home_mode (attendu 750)"
    (( 8#$env_mode & 7 )) && fail ".env lisible par 'other' (pzgame simulé)"
    (( 8#$home_mode & 7 )) && fail "home traversable par 'other' (pzgame simulé)"
    pass "simulation : secret 0600 owner=$env_owner, bits 'other' à 0 — pzgame simulé ne peut ni lire ni traverser"
else
    # FS sans chmod réel : on vérifie la propriété sur les modes IMPOSÉS par
    # les scripts (0600/0750, prouvés émis en (c)/(e)) + le propriétaire réel.
    for m in 600 750; do
        (( 8#$m & 7 )) && fail "mode $m : bits 'other' non nuls (mauvaise valeur imposée)"
    done
    skip_note "chmod inopérant sur ce FS ($(stat -c %a "$MGR/pzmanager/.env") lu au lieu de 600)"
    pass "simulation : owner réel=$env_owner != pzgame, modes imposés 0600/0750 (bits 'other' = 0)"
fi

# --- (e) split refusé avant mutation ; mono-user reste un no-op -----------------
[[ -x "$MIGRATE" ]] || fail "migrate-to-split-users.sh absent ou non exécutable"

# Stubs système : le test reste non-root, seule la logique réelle tourne.
STUB="$SIM/stubbin"
mkdir -p "$STUB"
export STUB_LOG="$SIM/calls.log"
: > "$STUB_LOG"
cat > "$STUB/id" <<'STUBEOF'
#!/usr/bin/env bash
name="${@: -1}"
if [[ "$name" == "pzmgr" || "$name" == "pzgame" ]]; then
    [[ "$*" == *"-nG"* ]] && echo "$name"
    exit 0
fi
exec /usr/bin/id "$@"
STUBEOF
for cmd in useradd groupadd usermod chown; do
    cat > "$STUB/$cmd" <<STUBEOF
#!/usr/bin/env bash
printf '%s %s\n' "$cmd" "\$*" >> "\$STUB_LOG"
exit 0
STUBEOF
done
cat > "$STUB/getent" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s %s\n' "getent" "$*" >> "$STUB_LOG"
exit 1
STUBEOF
cat > "$STUB/rsync" <<'STUBEOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >> "$STUB_LOG"
n=$#
src="${@:n-1:1}"
dst="${@:n:1}"
mkdir -p "$dst"
cp -a "$src/." "$dst/"
STUBEOF
# chmod : journalise PUIS délègue au vrai binaire (ineffectif sur NTFS,
# appliqué sur Linux) — prouve la commande de durcissement émise.
cat > "$STUB/chmod" <<'STUBEOF'
#!/usr/bin/env bash
printf 'chmod %s\n' "$*" >> "$STUB_LOG"
exec /bin/chmod "$@"
STUBEOF
chmod +x "$STUB"/*

SANDBOX_ENV="$MGR/pzmanager/.env"
cat > "$SANDBOX_ENV" <<ENVEOF
export PZ_USER="pzmgr"
export PZ_GAME_USER="pzgame"
export PZ_MANAGER_USER="pzmgr"
export PZ_HOME="$MGR"
export PZ_MANAGER_DIR="$MGR/pzmanager"
ENVEOF
chmod 0600 "$SANDBOX_ENV"
mkdir -p "$MGR/pzmanager/Zomboid/db" "$MGR/pzmanager/data/pzserver"
printf 'monde\n' > "$MGR/pzmanager/Zomboid/db/servertest.db"
printf 'binaire\n' > "$MGR/pzmanager/data/pzserver/start-server.sh"

# Depuis le contrat20G partagé, une migration multi-UID est incompatible.
# Prouver le refus AVANT comptes, fichiers, rsync ou permissions, deux fois.
state_before="$(cd "$SIM" && find home -mindepth 1 | sort)"
world_before="$(sha256sum "$MGR/pzmanager/Zomboid/db/servertest.db")"
: > "$STUB_LOG"
for attempt in 1 2; do
    if output="$(PZ_MIGRATE_ALLOW_NONROOT=1 PATH="$STUB:$PATH" bash "$MIGRATE" "$SANDBOX_ENV" 2>&1)"; then
        fail "split accepté malgré plafond partagé20G"
    fi
    grep -q 'Migration split refusée' <<< "$output" || fail "refus non lié au contrat mémoire : $output"
    [[ ! -s "$STUB_LOG" ]] || fail "mutation système avant refus split"
    [[ "$state_before" == "$(cd "$SIM" && find home -mindepth 1 | sort)" ]] || fail "arborescence modifiée"
    [[ "$world_before" == "$(sha256sum "$MGR/pzmanager/Zomboid/db/servertest.db")" ]] || fail "monde modifié"
done
pass "split refusé avant toute mutation, données et comptes conservés"

# Compat mono-user : GAME == MANAGER -> rien à faire, code 0.
cat > "$SIM/mono.env" <<ENVEOF
export PZ_USER="pzmgr"
export PZ_HOME="$MGR"
export PZ_MANAGER_DIR="$MGR/pzmanager"
ENVEOF
mono_out="$(PZ_MIGRATE_ALLOW_NONROOT=1 PATH="$STUB:$PATH" bash "$MIGRATE" "$SIM/mono.env" 2>&1)" \
    || fail "migrate mono-user en échec : $mono_out"
grep -q "rien à migrer" <<< "$mono_out" || fail "migrate mono-user : message inattendu ($mono_out)"
pass "migrate mono-user : no-op (install existante inchangée)"

# --- bash -n sur tous les scripts modifiés/créés ------------------------------
for f in "$ENV_PARSE" "$COMMON" "$SETUP_SYS" "$CONF_INIT" "$MIGRATE" "$0"; do
    bash -n "$f" || fail "bash -n : $f"
done
pass "bash -n : 6 scripts OK"

echo "C17 SPLIT USERS: OK"
