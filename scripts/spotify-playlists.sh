#!/usr/bin/env bash
# spotify-playlists.sh — daftar playlist Spotify akun sendiri (termasuk private),
# output JSON untuk migrasi playlist (Spotify -> Player Studio / YT Music).
#
# Butuh: curl, jq, python3, dan Client ID/Secret dari developer.spotify.com.
# Setup sekali (2 menit, gratis):
#   1. https://developer.spotify.com/dashboard -> Create app
#   2. Redirect URI: http://localhost:8080/callback
#   3. export SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=...
#      (atau tulis ke ~/.config/spotify-playlists/credentials)
#
# Run:  ./scripts/spotify-playlists.sh        # tabel ringkas + playlists.json
#       ./scripts/spotify-playlists.sh --json # JSON penuh ke stdout

set -euo pipefail

PORT=8080
CONFIG_DIR="${SPOTIFY_CONFIG_DIR:-$HOME/.config/spotify-playlists}"
CRED_FILE="$CONFIG_DIR/credentials"
TOKEN_FILE="$CONFIG_DIR/token.json"
CALLBACK_FILE="$(mktemp -t spotify-callback.XXXXXX)"
trap 'rm -f "$CALLBACK_FILE"' EXIT

die() { echo "error: $*" >&2; exit 1; }

# --- kredensial -----------------------------------------------------------
load_credentials() {
  CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
  CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:-}"
  if [[ -z "$CLIENT_ID" && -f "$CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
  fi
  if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
    echo "Butuh Client ID & Secret dari Spotify Developer Dashboard (gratis, 2 menit):" >&2
    echo "  1. Buka https://developer.spotify.com/dashboard -> Create app" >&2
    echo "  2. Redirect URI: http://localhost:$PORT/callback" >&2
    echo "  3. export SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=..." >&2
    echo "     atau buat file $CRED_FILE berisi: CLIENT_ID=... CLIENT_SECRET=..." >&2
    exit 1
  fi
  if [[ -n "${SPOTIFY_CLIENT_ID:-}" ]]; then  # simpan dari env untuk run berikutnya
    mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"
    printf 'CLIENT_ID=%s\nCLIENT_SECRET=%s\n' "$CLIENT_ID" "$CLIENT_SECRET" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
  fi
}

# --- OAuth ----------------------------------------------------------------
save_token() {  # $1=resp token JSON, $2=refresh_token
  mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"
  jq --arg rt "$2" --argjson exp "$(( $(date +%s) + 3500 ))" \
    '.refresh_token = $rt | .expires_at = $exp' <<<"$1" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
}

oauth_login() {
  local code resp
  python3 - "$PORT" "$CALLBACK_FILE" <<'PY' &
import http.server, os, socketserver, sys, time, urllib.parse
port, out = int(sys.argv[1]), sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = q.get("code", [""])[0]
        with open(out, "w") as f:
            f.write(code)
        body = (b"<h3>OK, kembali ke terminal.</h3>" if code
                else b"<h3>Gagal / ditolak.</h3>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

class S(socketserver.TCPServer):
    allow_reuse_address = True

httpd = S(("127.0.0.1", port), H)
httpd.timeout = 0.2
deadline = time.time() + 180
while time.time() < deadline:
    httpd.handle_request()
    if os.path.exists(out) and os.path.getsize(out):
        break
PY
  local py_pid=$!
  open "https://accounts.spotify.com/authorize?client_id=$CLIENT_ID&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A$PORT%2Fcallback&scope=playlist-read-private%20playlist-read-collaborative"
  for _ in $(seq 1 180); do
    kill -0 "$py_pid" 2>/dev/null || die "callback server mati (port $PORT dipakai?)"
    [[ -s "$CALLBACK_FILE" ]] && break
    sleep 1
  done
  wait "$py_pid" 2>/dev/null || true
  code=$(cat "$CALLBACK_FILE")
  [[ -n "$code" ]] || die "tidak dapat kode OAuth (timeout 3 menit)"
  resp=$(curl -s -X POST https://accounts.spotify.com/api/token \
    -u "$CLIENT_ID:$CLIENT_SECRET" \
    -d grant_type=authorization_code \
    -d "code=$code" \
    -d "redirect_uri=http://localhost:$PORT/callback")
  jq -e .access_token >/dev/null <<<"$resp" \
    || die "token exchange gagal: $(jq -r '.error_description // .error // "?"' <<<"$resp")"
  save_token "$resp" "$(jq -r .refresh_token <<<"$resp")"
}

get_token() {
  if [[ -f "$TOKEN_FILE" ]] && (( $(date +%s) < $(jq -r .expires_at "$TOKEN_FILE") )); then
    ACCESS_TOKEN=$(jq -r .access_token "$TOKEN_FILE")
    return
  fi
  local refresh resp
  if [[ -f "$TOKEN_FILE" ]]; then
    refresh=$(jq -r .refresh_token "$TOKEN_FILE")
    if [[ "$refresh" != "null" && -n "$refresh" ]]; then
      resp=$(curl -s -X POST https://accounts.spotify.com/api/token \
        -u "$CLIENT_ID:$CLIENT_SECRET" \
        -d grant_type=refresh_token \
        -d "refresh_token=$refresh")
      if jq -e .access_token >/dev/null <<<"$resp"; then
        save_token "$resp" "$refresh"
        ACCESS_TOKEN=$(jq -r .access_token "$TOKEN_FILE")
        return
      fi
    fi
  fi
  oauth_login
}

# --- ambil playlist -------------------------------------------------------
fetch_playlists() {
  local offset=0 total resp t
  local -a pages=()
  while :; do
    resp=$(curl -s "https://api.spotify.com/v1/me/playlists?limit=50&offset=$offset" \
      -H "Authorization: Bearer $ACCESS_TOKEN")
    jq -e .items >/dev/null <<<"$resp" \
      || die "API error: $(jq -r '.error.message // .error_description // "?"' <<<"$resp")"
    total=$(jq -r .total <<<"$resp")
    t=$(mktemp); printf '%s' "$resp" > "$t"; pages+=("$t")
    offset=$((offset + 50))
    [[ $offset -ge $total ]] && break
  done
  jq -s '[.[].items[]]' "${pages[@]}" > "$OUT_JSON"
  rm -f "${pages[@]}"
}

# --- main -----------------------------------------------------------------
load_credentials
get_token
OUT_JSON="playlists.json"
fetch_playlists

if [[ "${1:-}" == "--json" ]]; then
  cat "$OUT_JSON"
else
  jq -r 'to_entries[] | "\(.key+1). \(.value.name) [\(.value.public | if . then "public" else "private" end)] - \(.value.tracks.total) track - \(.value.id)"' "$OUT_JSON"
  echo "$(jq length "$OUT_JSON") playlist -> $OUT_JSON"
fi
