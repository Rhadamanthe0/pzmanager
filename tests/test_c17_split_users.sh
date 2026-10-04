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

# --- (b) zomboid.service : identité split déclarée + durcissement ------------
for key in 'User=' 'NoNewPrivileges=true' 'ProtectSystem=strict' 'ReadWritePaths'; do
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
pass "zomboid.service : User= documenté (commenté, unité --user), durcissement + ReadWritePaths install/monde/logs"
grep -q 'SocketMode=0660' "$SOCKET" || fail "zomboid.socket : SocketMode 0660 perdu"
grep -q 'SocketGroup' "$SOCKET" || fail "zomboid.socket : SocketGroup non documenté"
pass "zomboid.socket : SocketMode 0660 conservé, SocketGroup documenté"

# --- (c) setupSystem.sh : deux comptes, groupe, secrets jamais exposés -------
grep -q 'target_user="${1:-$PZ_USER}"' "$SETUP_SYS" || fail "create_user non paramétrique"
grep -q 'create_user "$PZ_MANAGER_USER"' "$SETUP_SYS" || fail "compte manager non créé en split"
grep -q 'create_user "$PZ_GAME_USER"' "$SETUP_SYS" || fail "compte jeu non créé en split"
grep -qE 'groupadd( |$).*pzgame|groupadd pzgame' "$SETUP_SYS" || fail "groupe pzgame non créé"
grep -q 'usermod -aG pzgame' "$SETUP_SYS" || fail "manager non ajouté au groupe pzgame"
pass "setupSystem.sh : deux comptes + groupe pzgame (création idempotente)"
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

# configurationInitiale.sh : migration appelée avant le téléchargement.
grep -q 'migrate_single_to_split' "$CONF_INIT" || fail "migrate_single_to_split absent"
grep -q 'migrate_single_to_split "$PZ_SOURCE_DIR"\|migrate_item_to_split "\$PZ_SOURCE_DIR"' "$CONF_INIT" \
    || fail "le monde n'est pas migré par migrate_single_to_split"
awk '/if \[\[ "\$do_server_install" == true \]\]; then/{found=1} found && /migrate_single_to_split/{before_dl=1} found && /install_zomboid_dependencies/{exit !before_dl}' "$CONF_INIT" \
    || fail "migrate_single_to_split non appelée avant le téléchargement"
grep -q 'pre-split-bak' "$CONF_INIT" || fail "l'original du monde n'est pas conservé (.pre-split-bak)"
pass "configurationInitiale.sh : migrate_single_to_split avant download, monde jamais supprimé"

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

# --- (e) migrate-to-split-users.sh : idempotent, deux runs OK -----------------
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

run1_out="$(PZ_MIGRATE_ALLOW_NONROOT=1 PATH="$STUB:$PATH" bash "$MIGRATE" "$SANDBOX_ENV" 2>&1)" \
    || fail "migrate run 1 en échec : $run1_out"
if (( FS_LINKS )); then
    [[ -L "$MGR/pzmanager/Zomboid" ]] || fail "run 1 : Zomboid non basculé en lien"
    [[ -L "$MGR/pzmanager/data/pzserver" ]] || fail "run 1 : pzserver non basculé en lien"
    [[ "$(readlink "$MGR/pzmanager/Zomboid")" == "$GAME/pzmanager/Zomboid" ]] \
        || fail "run 1 : lien monde inattendu ($(readlink "$MGR/pzmanager/Zomboid"))"
else
    skip_note "ln -s non effectif sur ce FS — bascule vérifiée par message + état"
    grep -qF "Migré vers le compte jeu : $MGR/pzmanager/Zomboid -> $GAME/pzmanager/Zomboid" <<< "$run1_out" \
        || fail "run 1 : bascule monde non exécutée"
    grep -qF "Migré vers le compte jeu : $MGR/pzmanager/data/pzserver -> $GAME/pzmanager/data/pzserver" <<< "$run1_out" \
        || fail "run 1 : bascule serveur non exécutée"
fi
[[ -f "$GAME/pzmanager/Zomboid/db/servertest.db" ]] || fail "run 1 : monde non copié"
[[ -f "$MGR/pzmanager/Zomboid.pre-split-bak/db/servertest.db" ]] || fail "run 1 : original non conservé"
[[ -f "$GAME/pzmanager/data/pzserver/start-server.sh" ]] || fail "run 1 : serveur non copié"
# Preuve des commandes exigées par le brief, lue dans le journal des appels
# (le FS local pouvant ignorer chmod, cf. FS_MODES).
grep -q "rsync -a .*Zomboid" "$STUB_LOG" || fail "run 1 : rsync -a du monde non émis"
grep -q "chown -R pzgame:pzgame" "$STUB_LOG" || fail "run 1 : chown vers pzgame non émis"
grep -qF "chmod 0600 $SANDBOX_ENV" "$STUB_LOG" || fail "run 1 : chmod 0600 du .env non émis"
grep -qF "chmod 0700 $MGR/.ssh" "$STUB_LOG" || fail "run 1 : chmod 0700 du .ssh non émis"
if (( FS_MODES )); then
    [[ "$(stat -c %a "$SANDBOX_ENV")" == "600" ]] || fail "run 1 : .env non resserré"
    [[ "$(stat -c %a "$MGR/.ssh")" == "700" ]] || fail "run 1 : .ssh non resserré"
else
    skip_note "modes FS non vérifiables ici (chmod inopérant) — commandes prouvées via journal"
fi
grep -q "Migration split-users terminée" <<< "$run1_out" || fail "run 1 : résumé absent"
pass "migrate run 1 : monde+serveur vers pzgame, originaux conservés, résumé affiché"

state_before="$(cd "$SIM" && find home -mindepth 1 | sort)"
run2_out="$(PZ_MIGRATE_ALLOW_NONROOT=1 PATH="$STUB:$PATH" bash "$MIGRATE" "$SANDBOX_ENV" 2>&1)" \
    || fail "migrate run 2 en échec : $run2_out"
state_after="$(cd "$SIM" && find home -mindepth 1 | sort)"
[[ "$state_before" == "$state_after" ]] || fail "run 2 : arborescence modifiée (non idempotent)"
if (( FS_LINKS )); then
    grep -q "Déjà migré" <<< "$run2_out" || fail "run 2 : no-op non signalé"
else
    grep -qE "Déjà migré|déjà présente" <<< "$run2_out" || fail "run 2 : no-op non signalé"
fi
pass "migrate run 2 : no-op idempotent (état inchangé, code 0)"

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
