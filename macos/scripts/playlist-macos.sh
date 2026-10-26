#!/bin/bash

# Local default-theme playlist controls for the macOS menu bar app.
# All state lives in video-playlist.json; poster and videos never leave the Mac.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/common-macos.sh"

STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
STATE_FILE="$STATE_ROOT/video-playlist.json"
POSTER_FILE="$STATE_ROOT/poster.jpeg"
VIDEOS_DIR="$STATE_ROOT/videos"
/bin/mkdir -p "$STATE_ROOT" "$VIDEOS_DIR"

node_state() {
  ensure_node_runtime || return 1
  "$NODE" -e 'const fs=require("fs");const p=process.env.DREAM_SKIN_STATE_FILE;let s={schemaVersion:1,index:0,positionSeconds:0,muted:true,paused:false,softVeil:true,updatedAt:""};try{s=JSON.parse(fs.readFileSync(p,"utf8"))}catch{};process.stdout.write(JSON.stringify(s))' </dev/null
}

case "${1:-}" in
  state)
    DREAM_SKIN_STATE_FILE="$STATE_FILE" node_state
    printf '\n'
    ;;
  set)
    key="${2:-}"
    value="${3:-}"
    case "$key" in muted|paused|soft-veil) ;; *) printf 'Unknown playlist key: %s\n' "$key" >&2; exit 1 ;; esac
    case "$value" in true|false) ;; *) printf 'Value must be true or false\n' >&2; exit 1 ;; esac
    ensure_node_runtime || exit 1
    DREAM_SKIN_STATE_FILE="$STATE_FILE" DREAM_SKIN_STATE_KEY="$key" DREAM_SKIN_STATE_VALUE="$value" \
      "$NODE" -e 'const fs=require("fs"),path=require("path");const p=process.env.DREAM_SKIN_STATE_FILE;let s={schemaVersion:1,index:0,positionSeconds:0,muted:true,paused:false,softVeil:true,updatedAt:""};try{s=JSON.parse(fs.readFileSync(p,"utf8"))}catch{};const k=process.env.DREAM_SKIN_STATE_KEY,v=process.env.DREAM_SKIN_STATE_VALUE==="true";if(k==="muted")s.muted=v;else if(k==="paused")s.paused=v;else if(k==="soft-veil")s.softVeil=v;s.schemaVersion=1;s.updatedAt=new Date().toISOString();fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n");' </dev/null
    values="$(DREAM_SKIN_STATE_FILE="$STATE_FILE" "$NODE" -e 'const fs=require("fs");let s={};try{s=JSON.parse(fs.readFileSync(process.env.DREAM_SKIN_STATE_FILE,"utf8"))}catch{};process.stdout.write([s.muted!==false,s.paused===true,s.softVeil!==false].join(" "))' </dev/null)"
    read -r muted paused soft <<< "$values"
    "$NODE" "$SCRIPT_DIR/injector.mjs" --video-state --muted "$muted" --paused "$paused" --soft-veil "$soft" >/dev/null 2>&1 || true
    ;;
  poster)
    source_path="${2:-}"
    [ -f "$source_path" ] || { printf 'Poster file not found\n' >&2; exit 1; }
    case "${source_path##*.}" in jpg|JPG|jpeg|JPEG) ;; *) printf 'Choose a JPEG poster\n' >&2; exit 1 ;; esac
    size="$(/usr/bin/stat -f%z "$source_path")"
    [ "$size" -ge 1 ] && [ "$size" -le 10485760 ] || { printf 'Poster must be 1 byte to 10 MB\n' >&2; exit 1; }
    temporary="$STATE_ROOT/.poster-$$.jpeg"
    /bin/cp "$source_path" "$temporary"
    /bin/mv -f "$temporary" "$POSTER_FILE"
    ;;
  restore-poster)
    /bin/rm -f "$POSTER_FILE"
    ;;
  open-videos)
    /usr/bin/open "$VIDEOS_DIR"
    ;;
  rescan)
    /bin/date +%s > "$STATE_ROOT/playlist-rescan.request"
    ;;
  *)
    printf 'Usage: playlist-macos.sh state|set|poster|restore-poster|open-videos|rescan\n' >&2
    exit 1
    ;;
esac
