#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${METAPI_BASE_URL:-http://127.0.0.1:4000}"
DB_PATH="${METAPI_DB_PATH:-/root/metapi-deploy/data/hub.db}"
SITE_URL="${METAPI_SITE_URL:-}"
SITE_NAME="${METAPI_SITE_NAME:-}"
PLATFORM="${METAPI_PLATFORM:-}"
PLATFORM_USER_ID="${METAPI_PLATFORM_USER_ID:-}"
ENABLE_CHECKIN="${METAPI_ENABLE_CHECKIN:-1}"

die() {
  printf '错误：%s\n' "$1" >&2
  exit 1
}

for command_name in curl jq node sqlite3; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done

[[ -n "$SITE_URL" ]] || die '必须设置 METAPI_SITE_URL'
[[ "$BASE_URL" == http://127.0.0.1:* || "$BASE_URL" == http://localhost:* ]] \
  || die '默认只允许本机管理地址；请先核实实例身份再修改脚本'
[[ -r "$DB_PATH" ]] || die "无法只读访问运行数据库：$DB_PATH"

if [[ -n "$PLATFORM_USER_ID" && ! "$PLATFORM_USER_ID" =~ ^[1-9][0-9]*$ ]]; then
  die 'METAPI_PLATFORM_USER_ID 必须是正整数'
fi
[[ "$ENABLE_CHECKIN" == 0 || "$ENABLE_CHECKIN" == 1 ]] \
  || die 'METAPI_ENABLE_CHECKIN 只能是 0 或 1'

printf '请输入 Session Cookie（输入不会回显）：' >&2
IFS= read -r -s COOKIE_VALUE
printf '\n' >&2
[[ -n "$COOKIE_VALUE" ]] || die 'Cookie 不能为空'
trap 'unset COOKIE_VALUE AUTH_TOKEN' EXIT

AUTH_TOKEN="$({
  sqlite3 -readonly "$DB_PATH" \
    "SELECT value FROM settings WHERE key='auth_token' LIMIT 1;" 2>/dev/null || true
} | jq -er 'select(type == "string" and length > 0)' 2>/dev/null || true)"

if [[ -z "$AUTH_TOKEN" ]] && command -v docker >/dev/null 2>&1; then
  AUTH_TOKEN="$(docker inspect metapi --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^AUTH_TOKEN=//p' | head -n 1)"
fi
[[ -n "$AUTH_TOKEN" ]] || die '无法取得有效管理员 Token'

HTTP_BODY=''
HTTP_STATUS=''
http_json() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local raw

  if [[ -n "$payload" ]]; then
    raw="$(printf '%s' "$payload" | curl -sS --max-time 60 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_TOKEN") \
      -H 'Content-Type: application/json' \
      -X "$method" --data-binary @- -w $'\n%{http_code}' "${BASE_URL}${path}")"
  else
    raw="$(curl -sS --max-time 60 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_TOKEN") \
      -X "$method" -w $'\n%{http_code}' "${BASE_URL}${path}")"
  fi

  HTTP_STATUS="${raw##*$'\n'}"
  HTTP_BODY="${raw%$'\n'*}"
  [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] || die "管理 API 返回了无效状态：$path"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    local message
    message="$(printf '%s' "$HTTP_BODY" | jq -r '.message // .error // empty' 2>/dev/null || true)"
    [[ -n "$message" ]] || message="HTTP $HTTP_STATUS"
    die "$path 失败：$message"
  fi
  printf '%s' "$HTTP_BODY" | jq -e . >/dev/null 2>&1 || die "$path 未返回 JSON"
}

http_json GET '/api/sites'
SITES_JSON="$HTTP_BODY"
CANONICAL_URL="$(printf '%s' "$SITE_URL" | sed -E 's#[/]+$##')"
SITE_MATCHES="$(printf '%s' "$SITES_JSON" | jq --arg url "${CANONICAL_URL,,}" \
  '[.[] | select(((.url // "") | ascii_downcase | rtrimstr("/")) == $url)]')"
SITE_COUNT="$(printf '%s' "$SITE_MATCHES" | jq 'length')"
(( SITE_COUNT <= 1 )) || die '规范化 URL 匹配到多个站点，停止写入'

SITE_ACTION='existing'
if (( SITE_COUNT == 1 )); then
  SITE_ID="$(printf '%s' "$SITE_MATCHES" | jq -r '.[0].id')"
  SITE_NAME_RESOLVED="$(printf '%s' "$SITE_MATCHES" | jq -r '.[0].name')"
  PLATFORM_RESOLVED="$(printf '%s' "$SITE_MATCHES" | jq -r '.[0].platform')"
else
  if [[ -z "$PLATFORM" ]]; then
    DETECT_PAYLOAD="$(jq -nc --arg url "$SITE_URL" '{url:$url}')"
    http_json POST '/api/sites/detect' "$DETECT_PAYLOAD"
    PLATFORM="$(printf '%s' "$HTTP_BODY" | jq -r '.platform // empty')"
  fi
  [[ -n "$PLATFORM" ]] || die '无法识别站点平台，请设置 METAPI_PLATFORM'
  if [[ -z "$SITE_NAME" ]]; then
    SITE_NAME="$(printf '%s' "$CANONICAL_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s/^www\.//')"
  fi
  CREATE_SITE_PAYLOAD="$(jq -nc \
    --arg name "$SITE_NAME" --arg url "$SITE_URL" --arg platform "$PLATFORM" \
    '{name:$name,url:$url,platform:$platform}')"
  http_json POST '/api/sites' "$CREATE_SITE_PAYLOAD"
  SITE_ID="$(printf '%s' "$HTTP_BODY" | jq -er '.id')"
  SITE_NAME_RESOLVED="$(printf '%s' "$HTTP_BODY" | jq -r '.name')"
  PLATFORM_RESOLVED="$(printf '%s' "$HTTP_BODY" | jq -r '.platform')"
  SITE_ACTION='created'
fi

verify_session() {
  local verify_payload
  verify_payload="$(jq -nc \
    --argjson siteId "$SITE_ID" --arg token "$COOKIE_VALUE" \
    --arg platformUserId "$PLATFORM_USER_ID" '
    {siteId:$siteId,accessToken:$token,credentialMode:"session"}
    + (if $platformUserId == "" then {} else {platformUserId:($platformUserId|tonumber)} end)')"
  http_json POST '/api/accounts/verify-token' "$verify_payload"
  VERIFY_JSON="$HTTP_BODY"
}

VERIFY_JSON='{}'
verify_session
VERIFY_SUCCESS="$(printf '%s' "$VERIFY_JSON" | jq -r '.success // false')"
TOKEN_TYPE="$(printf '%s' "$VERIFY_JSON" | jq -r '.tokenType // empty')"

if [[ "$VERIFY_SUCCESS" != true || "$TOKEN_TYPE" != session ]] \
  && [[ -z "$PLATFORM_USER_ID" ]] \
  && [[ "$(printf '%s' "$VERIFY_JSON" | jq -r '.needsUserId // false')" == true ]]; then
  mapfile -t USER_ID_CANDIDATES < <(
    printf '%s\n' "$COOKIE_VALUE" \
      | node "$(dirname "$0")/extract_session_user_ids.mjs" \
      | jq -r '.[]' \
      | head -n 8
  )

  for candidate in "${USER_ID_CANDIDATES[@]}"; do
    [[ "$candidate" =~ ^[1-9][0-9]*$ ]] || continue
    PLATFORM_USER_ID="$candidate"
    verify_session
    VERIFY_SUCCESS="$(printf '%s' "$VERIFY_JSON" | jq -r '.success // false')"
    TOKEN_TYPE="$(printf '%s' "$VERIFY_JSON" | jq -r '.tokenType // empty')"
    if [[ "$VERIFY_SUCCESS" == true && "$TOKEN_TYPE" == session ]]; then
      break
    fi
  done
fi

[[ "$VERIFY_SUCCESS" == true && "$TOKEN_TYPE" == session ]] \
  || die "Session 验证失败：$(printf '%s' "$VERIFY_JSON" | jq -r '.message // "未知错误"')"
VERIFIED_USERNAME="$(printf '%s' "$VERIFY_JSON" | jq -r '.userInfo.username // empty')"
VERIFIED_USER_ID="$(printf '%s' "$VERIFY_JSON" | jq -r '.userInfo.id // 0')"
if [[ -z "$PLATFORM_USER_ID" && "$VERIFIED_USER_ID" =~ ^[1-9][0-9]*$ ]]; then
  PLATFORM_USER_ID="$VERIFIED_USER_ID"
fi

http_json GET '/api/accounts?refresh=1'
ACCOUNTS_JSON="$HTTP_BODY"
ACCOUNT_MATCHES="$(printf '%s' "$ACCOUNTS_JSON" | jq \
  --argjson siteId "$SITE_ID" --arg username "$VERIFIED_USERNAME" --argjson userId "$VERIFIED_USER_ID" '
  [.accounts[]
    | select(.siteId == $siteId)
    | . as $account
    | (($account.extraConfig // {})
        | if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end) as $config
    | select(
        ($userId > 0 and (($config.platformUserId // 0) | tonumber? // 0) == $userId)
        or ($username != "" and ($account.username // "") == $username)
      )
    | {id,username}]
  | unique_by(.id)')"
ACCOUNT_COUNT="$(printf '%s' "$ACCOUNT_MATCHES" | jq 'length')"
(( ACCOUNT_COUNT <= 1 )) || die '同站点匹配到多个同身份账号，停止重绑'

ACCOUNT_ACTION='created'
JOB_ID=''
if (( ACCOUNT_COUNT == 1 )); then
  ACCOUNT_ID="$(printf '%s' "$ACCOUNT_MATCHES" | jq -r '.[0].id')"
  REBIND_PAYLOAD="$(jq -nc --arg token "$COOKIE_VALUE" --arg platformUserId "$PLATFORM_USER_ID" '
    {accessToken:$token}
    + (if $platformUserId == "" then {} else {platformUserId:($platformUserId|tonumber)} end)')"
  http_json POST "/api/accounts/${ACCOUNT_ID}/rebind-session" "$REBIND_PAYLOAD"
  if [[ "$ENABLE_CHECKIN" == 1 ]]; then
    http_json PUT "/api/accounts/${ACCOUNT_ID}" '{"checkinEnabled":true}'
  fi
  ACCOUNT_ACTION='rebound'
else
  CREATE_ACCOUNT_PAYLOAD="$(jq -nc \
    --argjson siteId "$SITE_ID" --arg token "$COOKIE_VALUE" \
    --arg platformUserId "$PLATFORM_USER_ID" --arg enableCheckin "$ENABLE_CHECKIN" '
    {siteId:$siteId,accessToken:$token,credentialMode:"session",checkinEnabled:($enableCheckin == "1")}
    + (if $platformUserId == "" then {} else {platformUserId:($platformUserId|tonumber)} end)')"
  http_json POST '/api/accounts' "$CREATE_ACCOUNT_PAYLOAD"
  ACCOUNT_ID="$(printf '%s' "$HTTP_BODY" | jq -er '.id')"
  JOB_ID="$(printf '%s' "$HTTP_BODY" | jq -r '.jobId // empty')"
fi

if [[ -n "$JOB_ID" ]]; then
  for _ in {1..15}; do
    http_json GET "/api/tasks/${JOB_ID}"
    TASK_STATUS="$(printf '%s' "$HTTP_BODY" | jq -r '.status // empty')"
    [[ "$TASK_STATUS" == queued || "$TASK_STATUS" == running ]] || break
    sleep 1
  done
fi

http_json POST "/api/accounts/${ACCOUNT_ID}/balance"
BALANCE_JSON="$HTTP_BODY"

CHECKIN_JSON='{}'
if [[ "$ENABLE_CHECKIN" == 1 ]]; then
  http_json POST "/api/checkin/trigger/${ACCOUNT_ID}"
  CHECKIN_JSON="$HTTP_BODY"
fi

http_json GET '/api/accounts?refresh=1'
FINAL_ACCOUNT="$(printf '%s' "$HTTP_BODY" | jq --argjson id "$ACCOUNT_ID" \
  '.accounts[] | select(.id == $id)')"
[[ -n "$FINAL_ACCOUNT" ]] || die '验收时未找到目标账号'

LATEST_LOG='{}'
if [[ "$ENABLE_CHECKIN" == 1 ]]; then
  http_json GET "/api/checkin/logs?accountId=${ACCOUNT_ID}&limit=1"
  LATEST_LOG="$(printf '%s' "$HTTP_BODY" | jq '.[0] // {}')"
fi

jq -n \
  --arg siteAction "$SITE_ACTION" --argjson siteId "$SITE_ID" \
  --arg siteName "$SITE_NAME_RESOLVED" --arg platform "$PLATFORM_RESOLVED" \
  --arg accountAction "$ACCOUNT_ACTION" --argjson accountId "$ACCOUNT_ID" \
  --arg verifiedUsername "$VERIFIED_USERNAME" --argjson balance "$BALANCE_JSON" \
  --argjson account "$FINAL_ACCOUNT" --argjson checkin "$CHECKIN_JSON" \
  --argjson log "$LATEST_LOG" --arg enableCheckin "$ENABLE_CHECKIN" '
  {
    site:{action:$siteAction,id:$siteId,name:$siteName,platform:$platform},
    account:{
      action:$accountAction,id:$accountId,
      username:($account.username // $verifiedUsername),
      status:$account.status,
      balance:($account.balance // $balance.balance),
      balanceUsed:($account.balanceUsed // null),
      quota:($account.quota // $balance.quota),
      lastBalanceRefresh:($account.lastBalanceRefresh // null),
      lastCheckinAt:($account.lastCheckinAt // null)
    },
    checkin:(if $enableCheckin != "1" then {skipped:true}
      else {
        success:($checkin.success // false),
        status:($checkin.status // ($log.checkin_logs.status // null)),
        message:($checkin.message // ($log.checkin_logs.message // null)),
        reward:($log.checkin_logs.reward // $checkin.reward // null),
        createdAt:($log.checkin_logs.createdAt // null)
      } end)
  }'
