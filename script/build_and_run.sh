#!/usr/bin/env bash
set -euo pipefail

APP_NAME="BossPilot"
BUNDLE_ID="app.bosspilot.desktop"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
TEMP_ROOT=""
trap '[[ -z "$TEMP_ROOT" ]] || rm -rf "$TEMP_ROOT"' EXIT

usage() {
  echo "usage: $0 [run|--debug-run|--debug|--logs|--telemetry|--ui-preview]"
  echo "       $0 --verify [APP_OR_ZIP]"
  echo "       $0 --package"
  echo "       $0 --release vMAJOR.MINOR.PATCH [--publish] [--repo OWNER/REPO]"
  echo "       $0 [--greeting-delivery|--greeting-confirmation|--greeting-reset-confirmed-absent]"
}

fail() { echo "$*" >&2; exit 1; }

verify_release() {
  python3 - "$1" <<'PY'
"""校验发布白名单及常见敏感信息，不输出命中原文。"""
import re
import stat
import sys
import zipfile
from pathlib import Path

REQUIRED_FILES = {
    "Contents/Info.plist",
    "Contents/MacOS/BossPilot",
    "Contents/Resources/BossPilot.icns",
    "Contents/Resources/LICENSE",
    "Contents/_CodeSignature/CodeResources",
}
PATTERNS = {
    "本机用户路径": rb"/(?:Users|home)/[^/\x00\s]+/|/(?:private/)?var/folders/[A-Za-z0-9_/-]+",
    "API 密钥": rb"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}",
    "私钥": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
}
DIRECTORIES = {parent.as_posix() for name in REQUIRED_FILES for parent in Path(name).parents if parent != Path(".")}


def validate_entries(entries):
    if set(entries) != REQUIRED_FILES:
        raise ValueError("应用包文件与白名单不一致，可能包含运行数据或缺少必需资源")
    for data in entries.values():
        for label, pattern in PATTERNS.items():
            if re.search(pattern, data):
                raise ValueError(f"发布包包含{label}")
        for email in re.findall(rb"[A-Za-z0-9_.+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})", data):
            if not email.lower().endswith((b".invalid", b".example", b".test")) and email.lower() not in {
                b"example.com", b"example.org", b"example.net"
            }:
                raise ValueError("发布包包含非测试邮箱")


def verify(path):
    entries = {}
    if path.is_symlink():
        raise ValueError("发布包不能是符号链接")
    if path.is_dir():
        for item in path.rglob("*"):
            if item.is_symlink():
                raise ValueError("应用包不允许包含符号链接")
            if item.is_file():
                entries[item.relative_to(path).as_posix()] = item.read_bytes()
            elif item.relative_to(path).as_posix() not in DIRECTORIES:
                raise ValueError("应用包包含白名单之外的目录")
    else:
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                if stat.S_ISLNK(item.external_attr >> 16):
                    raise ValueError("压缩包不允许包含符号链接")
                if item.is_dir():
                    name = item.filename.removesuffix("/")
                    if name not in {"BossPilot.app", *("BossPilot.app/" + d for d in DIRECTORIES)}:
                        raise ValueError("压缩包包含白名单之外的目录")
                    continue
                if not item.filename.startswith("BossPilot.app/"):
                    raise ValueError("压缩包只能包含 BossPilot.app")
                name = item.filename[len("BossPilot.app/"):]
                if name in entries:
                    raise ValueError("压缩包存在重复文件")
                entries[name] = archive.read(item)
    validate_entries(entries)
    print("发布包检查通过：文件白名单、本机路径、邮箱及常见密钥模式")


# 内置反例检查，防止精简规则时放行运行数据或敏感信息。
clean = dict.fromkeys(REQUIRED_FILES, b"test@example.invalid")
validate_entries(clean)
invalid_entries = [dict(clean, **{"Contents/state.json": b"{}"})]
for sample in [b"/Users/developer/project/", b"/home/developer/project/", b"sk-proj-" + b"x" * 30,
               b"-----BEGIN PRIVATE KEY-----", b"person@company.com"]:
    invalid_entries.append({**clean, "Contents/MacOS/BossPilot": sample})
for entries in invalid_entries:
    try:
        validate_entries(entries)
    except ValueError:
        continue
    raise AssertionError("发布检查错误放行了测试反例")

if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        sys.exit(f"发布包检查失败：{error}")
PY
}

package_app() {
  local BINARY="$1" APP="$2" VERSION="${3:-}"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
  chmod +x "$APP/Contents/MacOS/$APP_NAME"
  cmp -s "$BINARY" "$APP/Contents/MacOS/$APP_NAME" || fail "应用副本与构建产物不一致"
  cp "$ROOT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT_DIR/Resources/BossPilot.icns" "$APP/Contents/Resources/BossPilot.icns"
  cp "$ROOT_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
  if [[ -n "$VERSION" ]]; then
    /usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
    /usr/bin/strip -S -x "$APP/Contents/MacOS/$APP_NAME"
  fi
  /usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  /usr/bin/codesign --verify --deep --strict "$APP"
}

check_release_source() {
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail "请先提交工作区修改再发布"
  [[ "$(git rev-parse HEAD)" == "$1" ]] || fail "构建期间提交已改变，请重新发布"
}

release_app() {
  [[ $# -gt 0 ]] || { usage >&2; exit 2; }
  local TAG="$1" PUBLISH=false REPO="" COMMIT="" REMOTE_REF REMOTE_TYPE REMOTE_COMMIT
  shift
  [[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "版本格式应为 v1.0.0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish) PUBLISH=true; shift ;;
      --repo)
        [[ $# -ge 2 && "$2" != --* ]] || fail "--repo 需要 OWNER/REPO"
        REPO="$2"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [[ "$(uname -s)" == Darwin ]] || fail "发布包需要在 macOS 构建"
  if $PUBLISH; then
    command -v gh >/dev/null || fail "请先安装 GitHub CLI 并执行 gh auth login"
    COMMIT="$(git rev-parse --verify HEAD 2>/dev/null)" || fail "请先提交代码并推送版本标签"
    check_release_source "$COMMIT"
    if [[ -n "$REPO" ]]; then
      REPO="$(gh repo view "$REPO" --json nameWithOwner --jq .nameWithOwner)"
    else
      REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
    fi
    REMOTE_REF="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '[.object.type, .object.sha] | @tsv')" || fail "请先推送 $TAG 标签到 $REPO"
    read -r REMOTE_TYPE REMOTE_COMMIT <<< "$REMOTE_REF"
    while [[ "$REMOTE_TYPE" == tag ]]; do
      REMOTE_REF="$(gh api "repos/$REPO/git/tags/$REMOTE_COMMIT" --jq '[.object.type, .object.sha] | @tsv')"
      read -r REMOTE_TYPE REMOTE_COMMIT <<< "$REMOTE_REF"
    done
    [[ "$REMOTE_TYPE" == commit && "$REMOTE_COMMIT" == "$COMMIT" ]] || fail "远端版本标签与当前提交不一致"
  fi

  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/BossPilot-release.XXXXXX")"
  local APP="$TEMP_ROOT/$APP_NAME.app" BIN_DIR ASSET
  # 独立构建并重写源码路径，避免复用带开发机信息的缓存。
  swift build -c release --scratch-path "$TEMP_ROOT/build" \
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=." \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=."
  BIN_DIR="$(swift build -c release --scratch-path "$TEMP_ROOT/build" --show-bin-path)"
  package_app "$BIN_DIR/$APP_NAME" "$APP" "${TAG#v}"
  verify_release "$APP"
  if ! "$APP/Contents/MacOS/$APP_NAME" --self-check >"$TEMP_ROOT/self-check.log" 2>&1; then
    tail -n 30 "$TEMP_ROOT/self-check.log" >&2
    fail "发布包自检失败"
  fi
  tail -n 1 "$TEMP_ROOT/self-check.log"
  ASSET="$APP_NAME-$TAG-macos-$(uname -m).zip"
  /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP" "$TEMP_ROOT/$ASSET"
  verify_release "$TEMP_ROOT/$ASSET"
  (cd "$TEMP_ROOT" && /usr/bin/shasum -a 256 "$ASSET" >"$ASSET.sha256")
  mkdir -p dist/releases
  cp "$TEMP_ROOT/$ASSET" "$TEMP_ROOT/$ASSET.sha256" dist/releases/
  echo "发布包：$ROOT_DIR/dist/releases/$ASSET"
  if $PUBLISH; then
    check_release_source "$COMMIT"
    gh release create "$TAG" "dist/releases/$ASSET" "dist/releases/$ASSET.sha256" \
      --repo "$REPO" --verify-tag --title "$APP_NAME $TAG" --generate-notes
  fi
}

running_pids() {
  /usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true
}

stop_running_instances() {
  local pids pid attempt
  pids="$(running_pids)"
  [[ -z "$pids" ]] && return 0

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && /bin/kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"

  # 等待超过 AppDelegate 的 12 秒写入宽限期，再考虑强制结束进程。
  for attempt in $(seq 1 150); do
    [[ -z "$(running_pids)" ]] && return 0
    sleep 0.1
  done

  pids="$(running_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && /bin/kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"

  for attempt in $(seq 1 20); do
    [[ -z "$(running_pids)" ]] && return 0
    sleep 0.1
  done

  echo "unable to stop existing $APP_NAME process before replacing the app bundle" >&2
  return 1
}

running_executable_identity() {
  local pid="$1"
  /usr/sbin/lsof -a -p "$pid" -d txt -Fni 2>/dev/null | /usr/bin/awk '
    /^i/ && inode == "" { inode = substr($0, 2) }
    /^n/ && path == "" { path = substr($0, 2) }
    END {
      if (path != "" && inode != "") print path "|" inode
    }
  '
}

wait_for_expected_process() {
  local expected_inode pids pid identity actual_path actual_inode attempt
  expected_inode="$(/usr/bin/stat -f '%i' "$APP_BINARY")"
  for attempt in $(seq 1 100); do
    pids="$(running_pids)"
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      identity="$(running_executable_identity "$pid")"
      actual_path="${identity%|*}"
      actual_inode="${identity##*|}"
      if [[ -n "$identity" && "$actual_path" == "$APP_BINARY" && "$actual_inode" == "$expected_inode" ]]; then
        echo "running binary verified: pid=$pid path=$actual_path inode=$actual_inode"
        return 0
      fi
    done <<< "$pids"
    sleep 0.1
  done

  echo "launched $APP_NAME did not match packaged path or inode: $APP_BINARY ($expected_inode)" >&2
  return 1
}


MODE="${1:-run}"
[[ $# -eq 0 ]] || shift
case "$MODE" in
  debug-run|debug|logs|telemetry|verify|ui-preview|package) MODE="--$MODE" ;;
esac
case "$MODE" in
  --help|-h) usage; exit 0 ;;
  --verify)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    if [[ $# -eq 1 ]]; then
      verify_release "$1"
      exit 0
    fi
    ;;
  --release)
    cd "$ROOT_DIR"
    release_app "$@"
    exit 0
    ;;
  run|--package|--debug-run|--debug|--logs|--telemetry|--ui-preview|--greeting-delivery|--greeting-confirmation|--greeting-reset-confirmed-absent)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
/usr/bin/plutil -lint Resources/Info.plist >/dev/null
[[ -s Resources/BossPilot.icns ]] || fail "missing app icon: Resources/BossPilot.icns"
BUILD_CONFIGURATION="release"
case "$MODE" in
  --debug-run|--debug|--ui-preview) BUILD_CONFIGURATION="debug" ;;
esac
swift build -c "$BUILD_CONFIGURATION"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$APP_NAME"
BUILD_FINGERPRINT="$(/usr/bin/shasum -a 256 "$BUILD_BINARY" | /usr/bin/awk '{print $1}')"
if [[ "$MODE" == "--verify" ]]; then
  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/BossPilot-verify.XXXXXX")"
  APP_BUNDLE="$TEMP_ROOT/$APP_NAME.app"
else
  APP_BUNDLE="$DIST_APP_BUNDLE"
  stop_running_instances
fi
package_app "$BUILD_BINARY" "$APP_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" "$@"
  if ! wait_for_expected_process; then
    stop_running_instances
    return 1
  fi
}

case "$MODE" in
  --package)
    echo "packaged app: $APP_BUNDLE (source sha256 $BUILD_FINGERPRINT)"
    ;;
  run|--debug-run)
    open_app
    ;;
  --debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    "$APP_BINARY" --self-check
    /usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
    [[ -s "$APP_BUNDLE/Contents/Resources/BossPilot.icns" ]]
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    echo "verified isolated app bundle: $APP_BUNDLE (source sha256 $BUILD_FINGERPRINT)"
    ;;
  --ui-preview)
    open_app --args --ui-preview
    ;;
  --greeting-delivery)
    "$APP_BINARY" --boss-greeting-delivery
    ;;
  --greeting-confirmation)
    "$APP_BINARY" --boss-greeting-confirmation
    ;;
  --greeting-reset-confirmed-absent)
    "$APP_BINARY" --boss-greeting-reset-confirmed-absent
    ;;
esac
