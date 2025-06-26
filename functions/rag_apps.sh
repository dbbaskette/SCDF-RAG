#!/bin/bash
# rag_apps.sh - Register/unregister custom apps for rag-stream

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
. "$SCRIPT_DIR/env_setup.sh"

register_hdfs_watcher_app() {
  local token="$1"; local scdf_url="$2"
  local uri="https://github.com/dbbaskette/hdfsWatcher/releases/download/v0.2.0/hdfsWatcher-0.2.0.jar"
  local resp
  resp=$(curl -s -k -X POST "$scdf_url/apps/source/hdfsWatcher" \
    -H "Authorization: Bearer $token" \
    -d "uri=$uri" \
    -H "Content-Type: application/x-www-form-urlencoded")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] hdfsWatcher registration failed: $msg"
    return 1
  else
    echo "[SUCCESS] hdfsWatcher registered."
    return 0
  fi
}

register_text_proc_app() {
  local token="$1"; local scdf_url="$2"
  local uri="https://github.com/dbbaskette/textProc/releases/download/v0.0.6/textProc-0.0.6-SNAPSHOT.jar"
  local resp
  resp=$(curl -s -k -X POST "$scdf_url/apps/processor/textProc" \
    -H "Authorization: Bearer $token" \
    -d "uri=$uri" \
    -H "Content-Type: application/x-www-form-urlencoded")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] textProc registration failed: $msg"
    return 1
  else
    echo "[SUCCESS] textProc registered."
    return 0
  fi
}

register_embed_proc_app() {
  local token="$1"; local scdf_url="$2"
  local uri="https://github.com/dbbaskette/embedProc/releases/download/v0.0.3/embedProc-0.0.3.jar"
  local resp
  resp=$(curl -s -k -X POST "$scdf_url/apps/processor/embedProc" \
    -H "Authorization: Bearer $token" \
    -d "uri=$uri" \
    -H "Content-Type: application/x-www-form-urlencoded")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] embedProc registration failed: $msg"
    return 1
  else
    echo "[SUCCESS] embedProc registered."
    return 0
  fi
}

unregister_hdfs_watcher_app() {
  local token="$1"; local scdf_url="$2"
  local resp
  resp=$(curl -s -k -X DELETE "$scdf_url/apps/source/hdfsWatcher" \
    -H "Authorization: Bearer $token")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] hdfsWatcher unregistration failed: $msg"
    return 1
  else
    echo "[SUCCESS] hdfsWatcher unregistered."
    return 0
  fi
}

unregister_text_proc_app() {
  local token="$1"; local scdf_url="$2"
  local resp
  resp=$(curl -s -k -X DELETE "$scdf_url/apps/processor/textProc" \
    -H "Authorization: Bearer $token")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] textProc unregistration failed: $msg"
    return 1
  else
    echo "[SUCCESS] textProc unregistered."
    return 0
  fi
}

unregister_embed_proc_app() {
  local token="$1"; local scdf_url="$2"
  local resp
  resp=$(curl -s -k -X DELETE "$scdf_url/apps/processor/embedProc" \
    -H "Authorization: Bearer $token")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] embedProc unregistration failed: $msg"
    return 1
  else
    echo "[SUCCESS] embedProc unregistered."
    return 0
  fi
}

register_custom_apps() {
  local token="$1"; local scdf_url="$2"
  local prop_file="$SCRIPT_DIR/../rag-stream.properties"
  if [[ ! -f "$prop_file" ]]; then
    echo "[ERROR] $prop_file not found!" >&2
    return 1
  fi
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^app\.([^.]+)\.type$ ]] || continue
    local app_name="${BASH_REMATCH[1]}"
    local app_type="$value"
    local github_url
    github_url=$(grep "app.${app_name}.github_url" "$prop_file" | cut -d'=' -f2-)
    if [[ -z "$github_url" ]]; then
      echo "[WARN] No github_url for $app_name, skipping."
      continue
    fi
    # Extract owner/repo from URL
    if [[ "$github_url" =~ github.com/([^/]+)/([^/]+) ]]; then
      local owner="${BASH_REMATCH[1]}"
      local repo="${BASH_REMATCH[2]}"
      # Query latest release from GitHub API
      local api_url="https://api.github.com/repos/$owner/$repo/releases/latest"
      local release_json=$(curl -s "$api_url")
      local jar_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("\\.jar$") and (test("SNAPSHOT") | not)) | .browser_download_url' | head -n1)
      local version=$(echo "$release_json" | jq -r '.tag_name // .name // "unknown"')
      # Fallback: allow SNAPSHOT jar if no release jar
      if [[ -z "$jar_url" ]]; then
        jar_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("\\.jar$")) | .browser_download_url' | head -n1)
      fi
      if [[ -z "$jar_url" ]]; then
        echo "[ERROR] No JAR asset found for $owner/$repo latest release. Skipping $app_name."
        continue
      fi
      echo "[REGISTER] $app_name | type: $app_type | version: $version"
      echo "  JAR: $jar_url"
      local resp
      resp=$(curl -s -k -X POST "$scdf_url/apps/$app_type/$app_name" \
        -H "Authorization: Bearer $token" \
        -d "uri=$jar_url" \
        -H "Content-Type: application/x-www-form-urlencoded")
      if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
        local msg
        msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
        if [[ "$msg" =~ "already registered as" ]]; then
          reg_url=$(echo "$msg" | sed -nE "s/.*already registered as (.*)/\1/p")
          echo "[SKIP] $app_name already registered at $reg_url"
        elif [[ "$msg" =~ "can only differ by a version" ]]; then
          echo "[ERROR] $app_name registration failed: $msg"
        else
          echo "[ERROR] $app_name registration failed: $msg"
        fi
      else
        echo "[SUCCESS] $app_name registered."
      fi
    else
      echo "[ERROR] Could not parse owner/repo from $github_url for $app_name."
    fi
  done < <(grep ".type=" "$prop_file")
}


unregister_custom_apps() {
  unregister_hdfs_watcher_app "$1" "$2"
  unregister_text_proc_app "$1" "$2"
  unregister_embed_proc_app "$1" "$2"
}

view_custom_apps() {
  local token="$1"; local scdf_url="$2"
  for app in "source/hdfsWatcher" "processor/textProc" "processor/embedProc"; do
    echo
    echo "==== $app ===="
    curl -s -k -H "Authorization: Bearer $token" "$scdf_url/apps/$app" | jq '{name: .name, type: .type, uri: .uri, version: .version}'
  done
}
