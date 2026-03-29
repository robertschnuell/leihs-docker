#!/bin/bash
# =============================================================================
# Leihs Docker - Functional Test Suite
# =============================================================================
# Tests core services, login flow, database state, and security headers.
#
# Usage:
#   export LEIHS_TEST_USER=admin@example.com
#   export LEIHS_TEST_PASS=yourpassword
#   ./test_all.sh
# =============================================================================

CURL=/usr/bin/curl
BASE=http://localhost:3100

TEST_USER="${LEIHS_TEST_USER:-}"
TEST_PASS="${LEIHS_TEST_PASS:-}"

if [ -z "$TEST_USER" ] || [ -z "$TEST_PASS" ]; then
  echo "Set LEIHS_TEST_USER and LEIHS_TEST_PASS env vars for login tests."
  echo "  export LEIHS_TEST_USER=user@example.com"
  echo "  export LEIHS_TEST_PASS=yourpassword"
  echo ""
fi

echo "============================================"
echo "  Leihs Docker Functional Test Suite"
echo "============================================"
echo ""

PASS=0
FAIL=0

check() {
  local desc="$1" expect="$2" actual="$3"
  if [ "$actual" = "$expect" ]; then
    echo "  [PASS] $desc (HTTP $actual)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $desc (expected $expect, got $actual)"
    FAIL=$((FAIL+1))
  fi
}

echo "--- Unauthenticated endpoint tests ---"
for path in /sign-in /sign-out /nginx-health; do
  code=$($CURL -s -o /dev/null -w "%{http_code}" "${BASE}${path}")
  check "GET $path" "200" "$code"
done

# Root should show login page (200 from my service)
code=$($CURL -s -o /dev/null -w "%{http_code}" "${BASE}/")
check "GET / (landing)" "200" "$code"

# Admin/borrow should redirect to sign-in when unauthenticated
for path in /admin/ /borrow/; do
  code=$($CURL -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 "${BASE}${path}")
  if [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "303" ]; then
    echo "  [PASS] GET $path unauthenticated (HTTP $code)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] GET $path unauthenticated (HTTP $code)"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "--- Login flow test ---"

if [ -z "$TEST_USER" ] || [ -z "$TEST_PASS" ]; then
  echo "  [SKIP] No credentials set, skipping login tests"
else

# Get CSRF token
SIGNIN_BODY=$($CURL -s -c /tmp/lh_cookies "${BASE}/sign-in")
CSRF=$(echo "$SIGNIN_BODY" | python3 -c "
import sys, urllib.parse, json
html = sys.stdin.read()
props = html.split('data-page-props=\"')[1].split('\"')[0]
data = json.loads(urllib.parse.unquote(props))
print(data['csrfToken']['value'])
" 2>/dev/null)

if [ -z "$CSRF" ]; then
  echo "  [FAIL] Could not extract CSRF token"
  FAIL=$((FAIL+1))
else
  echo "  [PASS] CSRF token obtained: ${CSRF:0:8}..."
  PASS=$((PASS+1))

  # Step 1: submit email
  code=$($CURL -s -o /dev/null -w "%{http_code}" \
    -b "leihs-anti-csrf-token=$CSRF" \
    -H "x-csrf-token: $CSRF" \
    -X POST "${BASE}/sign-in" \
    -d "user=$(echo $TEST_USER | sed 's/@/%40/g')")
  check "POST /sign-in (email)" "200" "$code"

  # Step 2: submit password
  HDR=$($CURL -s -D - -o /dev/null \
    -b "leihs-anti-csrf-token=$CSRF" \
    -H "x-csrf-token: $CSRF" \
    -X POST "${BASE}/sign-in" \
    -d "user=$(echo $TEST_USER | sed 's/@/%40/g')&password=$TEST_PASS")
  code=$(echo "$HDR" | grep "HTTP/" | tail -1 | awk '{print $2}')
  SESSION=$(echo "$HDR" | grep -i "set-cookie.*leihs-user-session" | sed 's/.*leihs-user-session=//;s/;.*//' | tr -d '\r')

  check "POST /sign-in (password -> 302)" "302" "$code"

  if [ -n "$SESSION" ]; then
    echo "  [PASS] Session cookie received: ${SESSION:0:8}..."
    PASS=$((PASS+1))
  else
    echo "  [FAIL] No session cookie received"
    FAIL=$((FAIL+1))
  fi
fi

echo ""
echo "--- Authenticated endpoint tests ---"

if [ -n "$SESSION" ]; then
  code=$($CURL -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 \
    -b "leihs-user-session=$SESSION" "${BASE}/")
  check "GET / (authenticated -> redirect)" "302" "$code"

  for path in /admin/ /borrow/; do
    code=$($CURL -s -o /dev/null -w "%{http_code}" \
      -b "leihs-user-session=$SESSION" "${BASE}${path}")
    check "GET $path (authenticated)" "200" "$code"
  done

  for path in /procure/status /my/auth-info; do
    code=$($CURL -s -o /dev/null -w "%{http_code}" \
      -b "leihs-user-session=$SESSION" "${BASE}${path}")
    check "GET $path (authenticated)" "200" "$code"
  done

  code=$($CURL -s -o /dev/null -w "%{http_code}" \
    -b "leihs-user-session=$SESSION" \
    -H "Accept: application/json" \
    "${BASE}/my/auth-info")
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    echo "  [PASS] GET /my/auth-info (HTTP $code)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] GET /my/auth-info (HTTP $code)"
    FAIL=$((FAIL+1))
  fi

  # Sign out
  CSRF2=$($CURL -s -b "leihs-user-session=$SESSION" "${BASE}/" | python3 -c "
import sys, urllib.parse, json
html = sys.stdin.read()
try:
  props = html.split('data-page-props=\"')[1].split('\"')[0]
  data = json.loads(urllib.parse.unquote(props))
  print(data.get('csrfToken', {}).get('value', ''))
except:
  print('')
" 2>/dev/null)
  if [ -n "$CSRF2" ]; then
    code=$($CURL -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 \
      -b "leihs-user-session=$SESSION;leihs-anti-csrf-token=$CSRF2" \
      -H "x-csrf-token: $CSRF2" \
      -X POST "${BASE}/sign-out")
    if [ "$code" = "302" ] || [ "$code" = "204" ] || [ "$code" = "200" ]; then
      echo "  [PASS] POST /sign-out (HTTP $code)"
      PASS=$((PASS+1))
    else
      echo "  [FAIL] POST /sign-out (HTTP $code)"
      FAIL=$((FAIL+1))
    fi
  fi
else
  echo "  [SKIP] No session, skipping authenticated tests"
fi

fi  # end credentials check

echo ""
echo "--- Service health tests ---"
CORE_SERVICES="leihs-legacy leihs-admin leihs-borrow leihs-my leihs-procure leihs-mail leihs-db"
for svc in $CORE_SERVICES; do
  status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null)
  if [ "$status" = "running" ]; then
    echo "  [PASS] $svc is running"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $svc status: $status"
    FAIL=$((FAIL+1))
  fi
done

# Check OIDC bridge only if it exists (optional component)
oidc_status=$(docker inspect --format='{{.State.Status}}' "leihs-oidc-bridge" 2>/dev/null)
if [ -n "$oidc_status" ]; then
  if [ "$oidc_status" = "running" ]; then
    echo "  [PASS] leihs-oidc-bridge is running (optional)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] leihs-oidc-bridge status: $oidc_status"
    FAIL=$((FAIL+1))
  fi
fi

echo ""
echo "--- Database connectivity ---"
tables=$(docker exec leihs-db psql -U leihs -d leihs -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' ')
if [ -n "$tables" ] && [ "$tables" -gt 50 ]; then
  echo "  [PASS] Database has $tables tables"
  PASS=$((PASS+1))
else
  echo "  [FAIL] Database table count: $tables"
  FAIL=$((FAIL+1))
fi

seeds=$(docker exec leihs-db psql -U leihs -d leihs -t -c "SELECT count(*) FROM groups WHERE id='4dd87663-f731-5766-b97d-9494889ca66c';" 2>/dev/null | tr -d ' ')
check "Seed data: All Users group" "1" "$seeds"

echo ""
echo "--- Security header tests ---"
HEADERS=$($CURL -s -D - -o /dev/null "${BASE}/")
for header in "X-Frame-Options" "X-Content-Type-Options" "Referrer-Policy" "Permissions-Policy"; do
  if echo "$HEADERS" | grep -qi "$header"; then
    echo "  [PASS] $header header present"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $header header missing"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"
