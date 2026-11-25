#!/usr/bin/env bash
# e2e-common.sh — 四个 e2e 脚本共享的认证与断言骨架（单一真源）。
# 用法：在各 e2e 脚本的变量定义之后 source 本文件：
#   . "$(dirname "${BASH_SOURCE[0]}")/e2e-common.sh"
# source 后提供：
#   TOKEN / AUTH 数组          认证（外部 TOKEN 优先，否则 password grant 动态换取）
#   PASS / FAIL / ok / bad     断言计数
#   jqf / jget                 JSON 表达式求值（jget 为历史别名，同实现）
#   req                        不计数的 HTTP 调用（method path [body] -> body；非 2xx 仅 stderr 提示）
# 脚本特有语义保留在各脚本内覆盖定义（如 e2e-smoke.sh 的计数版 req、
# e2e-cancel-rerun.sh 的 C() 带 --noproxy），source 之后再定义同名函数即可覆盖。
set -u

export no_proxy="${no_proxy:-*}" NO_PROXY="${NO_PROXY:-*}"
KC_ISSUER="${KC_ISSUER:-https://www.sdpworkflow.com/keycloak/realms/sdp}"
KC_CLIENT="${KC_CLIENT:-sdp-console}"
KC_USER="${KC_USER:-admin}"
KC_PASS="${KC_PASS:-sdp@12345}"
if [ -z "${TOKEN:-}" ]; then
  TOKEN=$(curl -sk -s "$KC_ISSUER/protocol/openid-connect/token" \
    -d grant_type=password -d client_id="$KC_CLIENT" \
    -d username="$KC_USER" -d password="$KC_PASS" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
  [ -n "$TOKEN" ] || { echo "错误: token 获取失败（${KC_ISSUER} client=${KC_CLIENT} user=${KC_USER}）" >&2; exit 1; }
  echo "  [info] token 获取成功（${KC_ISSUER}）" >&2
fi
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }

jqf() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
jget() { jqf "$1"; }   # 历史别名：与 jqf 同实现，保留以避免改名式大改

req() {  # method path [body] -> body；2xx 打 PASS 到 stderr 的职责移交给调用方断言
  local m="$1" p="$2" b="${3:-}" out code
  if [ -n "$b" ]; then
    out=$($CURL -w "\n%{http_code}" -X "$m" "$BASE$p" -H 'Content-Type: application/json' ${AUTH[@]+"${AUTH[@]}"} -d "$b")
  else
    out=$($CURL -w "\n%{http_code}" -X "$m" "$BASE$p" ${AUTH[@]+"${AUTH[@]}"})
  fi
  code="${out##*$'\n'}"; echo "${out%$'\n'*}"
  [[ "$code" =~ ^2 ]] || echo "  [http $code] $m $p" >&2
}
