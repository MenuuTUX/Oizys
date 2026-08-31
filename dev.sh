#!/bin/bash
# Build/install commands share the same Xcode targets as the IDE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
VARIANT="${OIZYS_VARIANT:-production}"
VERSION="$(cat VERSION)"
PYTHON="${OIZYS_PYTHON:-python3}"
SIGNING="${OIZYS_SIGN_IDENTITY:--}"

configuration() {
  case "$VARIANT" in
    production) echo Production ;; production-fallback) echo ProductionFallback ;;
    debug-minimal) echo DebugMinimal ;; debug-verbose) echo DebugVerbose ;;
    debug-fallback) echo DebugFallback ;; *) echo "Unknown variant: $VARIANT" >&2; return 2 ;;
  esac
}
scheme() {
  case "$VARIANT" in
    production) echo Oizys-production ;; production-fallback) echo Oizys-production-fallback ;;
    debug-minimal) echo Oizys-debug ;; debug-verbose) echo Oizys-debug-verbose ;;
    debug-fallback) echo Oizys-debug-fallback ;;
  esac
}
select_variant() {
  echo "1 Production   2 Production with fallback   3 Debug minimal   4 Debug verbose   5 Debug fallback"
  local answer
  read -r -p 'Variant: ' answer || return
  case "$answer" in
    1) VARIANT=production ;; 2) VARIANT=production-fallback ;; 3) VARIANT=debug-minimal ;;
    4) VARIANT=debug-verbose ;; 5) VARIANT=debug-fallback ;; *) echo 'Unchanged.' ;;
  esac
}
generate() { "$PYTHON" Tools/make_xcodeproj.py; }
build() { "$PYTHON" Tools/build_app.py --variant "$VARIANT" --sign "$SIGNING" "$@"; }
run_debug() {
  build --restart-debug
  "$ROOT/dist/Oizys-debug-$VERSION-$VARIANT" --developer-root "$ROOT"
}
cli() {
  if [[ -x /Applications/Oizys.app/Contents/MacOS/OizysDriver ]]; then
    /Applications/Oizys.app/Contents/MacOS/OizysDriver "$@"
  elif [[ -x "build/$(configuration)/oizys" ]]; then
    "build/$(configuration)/oizys" "$@"
  else
    echo 'Build or install Oizys first.' >&2; return 1
  fi
}
install_app() {
  case "$VARIANT" in debug-*) echo 'Debug is portable only. Choose Run debug; nothing is installed.' >&2; return 2 ;; esac
  build
  "$PYTHON" Tools/install_app.py "build/apps/$VARIANT/$VERSION/Oizys.app"
}
clean() {
  "$PYTHON" - "$ROOT" "$(configuration)" "$VARIANT" <<'PY'
from pathlib import Path
import shutil, subprocess, sys
root, configuration, variant = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
paths = [root/'build'/configuration, root/'build/apps'/variant,
         root/'build/Intermediates/Oizys.build'/configuration]
running = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
for path in paths:
    if str(path) + '/' in running:
        raise SystemExit('Quit the running build before cleaning it: ' + str(path))
for path in paths:
    if path.is_symlink(): path.unlink()
    elif path.exists(): shutil.rmtree(path)
    print('Cleaned:', path)
print('Installed production, portable downloads, dependencies and private settings were preserved.')
PY
}
doctor() {
  xcode-select -p
  xcodebuild -version
  "$PYTHON" --version
  echo "Variant: $VARIANT ($(configuration)); version: $VERSION"
  echo "Signing: $SIGNING (a dash means local ad-hoc signing, without notarization)"
  echo 'macOS controls Screen Recording approval; no script can grant it silently.'
  [[ -w /Applications ]] || echo '/Applications is not writable. Run installation from an authorized administrator account.'
  cli service status || true
}
profile() {
  case "${1:-encoder}" in
    encoder) "$PYTHON" Tools/profile.py --frames 120 --save "build/profile-$(date +%Y%m%d-%H%M%S).json" ;;
    gui)
      case "$VARIANT" in debug-*) ;; *) echo 'Select a debug variant for GUI profiling.' >&2; return 2 ;; esac
      generate
      xcodebuild -project Oizys.xcodeproj -scheme "$(scheme)" -configuration "$(configuration)" build
      xcrun xctrace record --template 'Time Profiler' --time-limit 30s \
        --output "build/gui-$(date +%Y%m%d-%H%M%S).trace" \
        --launch -- "$ROOT/build/$(configuration)/Oizys-debug.app/Contents/MacOS/Oizys-debug"
      ;;
    *) echo 'Use profile encoder or profile gui.' >&2; return 2 ;;
  esac
}
execute() {
  local command="$1"; shift
  case "$command" in
    build) build ;;
    install) install_app ;;
    run)
      case "$VARIANT" in
        debug-*) run_debug ;;
        *) cli service start ;;
      esac ;;
    tui) cli tui ;;
    status) cli service status ;;
    stop) cli service stop ;;
    clean) clean ;;
    setup) "$PYTHON" Tools/setup_debug.py ;;
    debug)
      VARIANT="${1:-debug-minimal}"
      case "$VARIANT" in debug-minimal|debug-verbose|debug-fallback) ;; *) echo 'Choose a debug variant.' >&2; return 2 ;; esac
      run_debug ;;
    build-debug-all)
      for VARIANT in debug-minimal debug-verbose debug-fallback; do build; done ;;
    test) "$PYTHON" Tools/test.py "$@" ;;
    coverage) "$PYTHON" Tools/test.py --coverage "$@" ;;
    sanitize) "$PYTHON" Tools/test.py --sanitize "${1:-address}" ;;
    profile) profile "$@" ;;
    analyze) generate; xcodebuild -project Oizys.xcodeproj -scheme "$(scheme)" -configuration "$(configuration)" analyze ;;
    archive) generate; xcodebuild -project Oizys.xcodeproj -scheme "$(scheme)" -configuration "$(configuration)" \
                  -archivePath "$ROOT/build/archives/$VARIANT-$VERSION.xcarchive" archive ;;
    xcode) generate; open Oizys.xcodeproj ;;
    permissions) open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' ;;
    doctor) doctor ;;
    help|--help|-h)
      echo './dev.sh [build|install|run|clean|archive|analyze] [variant]'
      echo './dev.sh [tui|status|stop|setup|test|coverage|sanitize|profile|xcode|permissions|doctor] [arguments]'
      echo './dev.sh debug [debug-minimal|debug-verbose|debug-fallback]  # replace the previous debug session and run'
      echo './dev.sh build-debug-all  # prepare all portable debug variants without replacing production'
      echo 'Variants: production, production-fallback, debug-minimal, debug-verbose, debug-fallback'
      echo 'No arguments opens the menu. Builds never run tests or touch installed apps.' ;;
    *) echo "Unknown command: $command" >&2; return 2 ;;
  esac
}

if (($#)); then
  command="$1"; shift
  case "$command" in
    build|install|run|clean|archive|analyze)
      if (($#)); then VARIANT="$1"; shift; fi
      configuration >/dev/null ;;
  esac
  execute "$command" "$@"
  exit
fi
[[ -t 0 && -t 1 ]] || { execute help; exit 2; }
while true; do
  [[ "${TERM:-dumb}" == dumb ]] || printf '\033[2J\033[H'
  echo "Oizys developer tools · $VERSION · $VARIANT"
  echo '1 Variant     2 Build         3 Run           4 Install production'
  echo '5 Clean       6 Setup tests   7 Run tests     8 Coverage'
  echo '9 ASan        u UBSan         t TSan          p Encoder profile'
  echo 'g GUI profile x Open Xcode    a Analyze       z Xcode archive'
  echo 'm Monitor TUI s Status        d Doctor        r Recording permission'
  echo 'q Quit'
  read -r -p '> ' answer || break
  case "$answer" in
    1) select_variant; continue ;; q) break ;;
    2) command=build ;; 3) command=run ;; 4) command=install ;; 5) command=clean ;;
    6) command=setup ;; 7) command=test ;; 8) command=coverage ;; 9|u|t) command=sanitize ;;
    p|g) command=profile ;; x) command=xcode ;; a) command=analyze ;; z) command=archive ;;
    m) command=tui ;; s) command=status ;; d) command=doctor ;; r) command=permissions ;;
    *) continue ;;
  esac
  extra=()
  case "$answer" in 9) extra=(address) ;; u) extra=(undefined) ;; t) extra=(thread) ;; p) extra=(encoder) ;; g) extra=(gui) ;; esac
  # A subprocess preserves fail-fast behavior inside commands while keeping the menu open.
  if OIZYS_VARIANT="$VARIANT" "$ROOT/dev.sh" "$command" ${extra[@]+"${extra[@]}"}; then
    echo 'Done.'
  else
    echo 'Command failed; see the message above. No privacy settings were reset.'
  fi
  read -r -p 'Press Return to continue…' answer || break
 done
