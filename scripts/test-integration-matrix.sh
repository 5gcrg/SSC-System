#!/bin/bash
# Full integration-hardening verification matrix. Prints PASS/FAIL per check.
export MSYS2_ARG_CONV_EXCL="*"
export MSYS_NO_PATHCONV=1

S="$(dirname "$0")"
B=http://localhost:8081/api/v1/integration
PUB=http://localhost:8081/api/v1
F=http://localhost:8080/api/v1/integration/files
LEGACY="legacy-key-0000111122223333"
SENS="test-key-s-aaaabbbbccccdddd"
A="test-key-a-0123456789abcdef"
B2="test-key-b-fedcba9876543210"

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1 ($3)";
  else fail=$((fail+1)); echo "FAIL  $1 (expected $2, got $3)"; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "===== BACKEND ====="
check "masterlist GET legacy key"        200 "$(code -H "X-API-Key: $LEGACY" $B/masterlist)"
check "masterlist GET by id"             200 "$(code -H "X-API-Key: $LEGACY" $B/masterlist/1234-5678-9)"
check "masterlist GET no key"            401 "$(code $B/masterlist)"
check "masterlist GET wrong key"         403 "$(code -H 'X-API-Key: wrong' $B/masterlist)"
check "masterlist POST valid key"        405 "$(code -X POST -H "X-API-Key: $LEGACY" -H 'Content-Type: application/json' -d '{}' $B/masterlist)"
check "masterlist POST batch"            405 "$(code -X POST -H "X-API-Key: $LEGACY" -H 'Content-Type: application/json' -d '[]' $B/masterlist/batch)"
check "masterlist PUT"                   405 "$(code -X PUT -H "X-API-Key: $LEGACY" $B/masterlist)"
check "sensitive w/ legacy (denied)"     403 "$(code -H "X-API-Key: $LEGACY" "$B/masterlist?includeSensitive=true")"
check "sensitive w/ client2 (allowed)"   200 "$(code -H "X-API-Key: $SENS" "$B/masterlist?includeSensitive=true")"
check "departments w/ key"               200 "$(code -H "X-API-Key: $LEGACY" $B/departments)"
check "departments no key"               401 "$(code $B/departments)"
check "departments POST"                 405 "$(code -X POST -H "X-API-Key: $LEGACY" $B/departments)"
check "organizations w/ key+filter"      200 "$(code -H "X-API-Key: $LEGACY" "$B/organizations?active=true")"
deptid=$(curl -s -H "X-API-Key: $LEGACY" $B/departments | grep -oE '"departmentId":"[^"]+"' | head -1 | cut -d'"' -f4)
check "departments/{id} w/ key"          200 "$(code -H "X-API-Key: $LEGACY" $B/departments/$deptid)"
orgid=$(curl -s -H "X-API-Key: $LEGACY" $B/organizations | grep -oE '"orgId":"[^"]+"' | head -1 | cut -d'"' -f4)
check "organizations/{id} w/ key"        200 "$(code -H "X-API-Key: $LEGACY" $B/organizations/$orgid)"
check "public /departments no key"       200 "$(code $PUB/departments)"
check "public /organizations no key"     200 "$(code $PUB/organizations)"
codes=$(for i in $(seq 1 40); do code -H "X-API-Key: $LEGACY" $B/departments; echo; done)
n429=$(echo "$codes" | grep -c 429)
n200=$(echo "$codes" | grep -c 200)
# Earlier matrix calls share this key's bucket, so the burst can't expect a full 30 window;
# the invariant is: both outcomes occur, nothing else, and successes never exceed capacity.
[ "$n429" -ge 1 ] && [ "$n200" -ge 1 ] && [ "$n200" -le 30 ] && [ $((n200 + n429)) -eq 40 ] && burst=ok || burst="200s=$n200 429s=$n429"
check "burst 40 reqs -> mixed 200/429, <=30 successes" ok "$burst"
ra=$(curl -s -D - -o /dev/null -H "X-API-Key: $LEGACY" $B/departments | grep -i '^retry-after:' | tr -d '\r' | awk '{print $2}')
[ -n "$ra" ] && [ "$ra" -ge 1 ] && check "429 Retry-After header present" ok ok || check "429 Retry-After header present" ok "missing"

echo "===== FILESERVER ====="
printf 'PK-test-content-12345' > "$S/app.zip"
r=$(curl -s -H "X-API-Key: $A" -F "file=@$S/app.zip" -F "path=builds/v1/app.zip" $F)
echo "$r" | grep -q '"overwritten":false' && check "upload -> overwritten:false" ok ok || check "upload -> overwritten:false" ok "$r"
r=$(curl -s -H "X-API-Key: $A" -F "file=@$S/app.zip" -F "path=builds/v1/app.zip" $F)
echo "$r" | grep -q '"overwritten":true' && check "re-upload -> overwritten:true" ok ok || check "re-upload -> overwritten:true" ok "$r"
check "files no key"                     401 "$(code "$F")"
check "files wrong key"                  403 "$(code -H 'X-API-Key: nope' "$F")"
for p in "../other/app.zip" "/etc/passwd" 'a\..\b' "a//b" ".." "builds/%2e%2e/x"; do
  check "traversal upload '$p'"          403 "$(code -H "X-API-Key: $A" -F "file=@$S/app.zip" -F "path=$p" $F)"
done
check "traversal list prefix=../"        403 "$(code -H "X-API-Key: $A" "$F?prefix=../")"
check "traversal url path=../x"          403 "$(code -H "X-API-Key: $A" "$F/url?path=../x")"
check "blocked extension .exe"           400 "$(code -H "X-API-Key: $A" -F "file=@$S/app.zip" -F "path=run.exe" $F)"
[ -f "$S/big.bin" ] || dd if=/dev/zero of="$S/big.bin" bs=1048576 count=26 2>/dev/null
check "oversize 26MB"                    400 "$(code -H "X-API-Key: $A" -F "file=@$S/big.bin" -F "path=big.bin" $F)"
r=$(curl -s -H "X-API-Key: $B2" "$F")
[ "$r" = '{"files":[],"truncated":false,"nextStartAfter":null}' ] && check "KEY_B list isolated (empty)" ok ok || check "KEY_B list isolated (empty)" ok "$r"
check "KEY_B url for A's path"           404 "$(code -H "X-API-Key: $B2" "$F/url?path=builds/v1/app.zip")"
url=$(curl -s -H "X-API-Key: $A" "$F/url?path=builds/v1/app.zip" | grep -oE '"presignedUrl":"[^"]+"' | cut -d'"' -f4)
body=$(curl -s "$url")
check "presigned fetch content"          "PK-test-content-12345" "$body"
echo "$url" | grep -q "/ssc-projects/projects/acme-app/builds/v1/app.zip" && check "key layout in bucket" ok ok || check "key layout in bucket" ok "$url"
curl -s -o /dev/null -H "X-API-Key: $A" -F "file=@$S/app.zip" -F "path=builds/v2/app.zip" $F
curl -s -o /dev/null -H "X-API-Key: $A" -F "file=@$S/app.zip" -F "path=docs/readme.md" $F
p1=$(curl -s -H "X-API-Key: $A" "$F?maxKeys=2")
echo "$p1" | grep -q '"truncated":true' && check "pagination page1 truncated" ok ok || check "pagination page1 truncated" ok "$p1"
next=$(echo "$p1" | grep -oE '"nextStartAfter":"[^"]+"' | cut -d'"' -f4)
p2=$(curl -s -H "X-API-Key: $A" "$F?maxKeys=2&startAfter=$next")
echo "$p2" | grep -q 'docs/readme.md' && echo "$p2" | grep -q '"truncated":false' && check "pagination page2 has 3rd file" ok ok || check "pagination page2 has 3rd file" ok "$p2"
check "delete"                           204 "$(code -X DELETE -H "X-API-Key: $A" "$F?path=docs/readme.md")"
check "delete again (idempotent)"        204 "$(code -X DELETE -H "X-API-Key: $A" "$F?path=docs/readme.md")"
check "url after delete"                 404 "$(code -H "X-API-Key: $A" "$F/url?path=docs/readme.md")"
check "JWT-gated /api/v1/files no auth"  403 "$(code "http://localhost:8080/api/v1/files/documents/url?objectKey=x")"
check "fileserver health"                200 "$(code http://localhost:8080/actuator/health)"
check "backend ping"                     200 "$(code http://localhost:8081/api/v1/ping)"

# cleanup test objects
curl -s -o /dev/null -X DELETE -H "X-API-Key: $A" "$F?path=builds/v1/app.zip"
curl -s -o /dev/null -X DELETE -H "X-API-Key: $A" "$F?path=builds/v2/app.zip"

echo "===== RESULT: $pass passed, $fail failed ====="
[ "$fail" -eq 0 ]
