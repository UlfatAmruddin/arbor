# Signs Arbor.app and the code nested in it, inside out: each framework's XPC services, helper apps and
# helper tools, then the framework, then the app. Never `codesign --deep`, which would give nested code
# the app's options and entitlements. Shared by build-app.sh and sign-and-notarize.sh.
#
#   . scripts/lib/codesign-app.sh
#   arbor_codesign_app <app> <identity> [codesign options for every item…]
#   arbor_signed_code <app>        prints every signed item, inside out, the app last
#
# <identity> is "-" for ad-hoc. Nested code keeps its own identifier and entitlements; the app gets
# ARBOR_ENTITLEMENTS when that is set. Stops at the first failure (codesign's message says why).

arbor_signed_code() {
  local app="$1" framework version item
  for framework in "$app"/Contents/Frameworks/*.framework; do
    [ -d "$framework" ] || continue
    version="$framework/Versions/$(readlink "$framework/Versions/Current")"
    for item in "$version"/XPCServices/*.xpc "$version"/*.app; do
      if [ -d "$item" ]; then echo "$item"; fi
    done
    # Helper tools (Sparkle's Autoupdate) sit beside the framework's own binary.
    for item in "$version"/*; do
      if [ -f "$item" ] && [ -x "$item" ] && [ "$(basename "$item")" != "$(basename "$framework" .framework)" ]; then echo "$item"; fi
    done
    echo "$framework"
  done
  echo "$app"
}

arbor_codesign_app() {
  local app="$1" identity="$2"; shift 2
  local options=("$@") item extra output
  while IFS= read -r item; do
    if [ "$item" = "$app" ]; then
      extra=()
      if [ -n "${ARBOR_ENTITLEMENTS:-}" ]; then extra=(--entitlements "$ARBOR_ENTITLEMENTS"); fi
    elif [[ "$item" == *.framework ]]; then
      extra=()
    else
      extra=(--preserve-metadata=identifier,entitlements)
    fi
    if ! output="$(codesign --force --sign "$identity" ${options[@]+"${options[@]}"} ${extra[@]+"${extra[@]}"} "$item" 2>&1)"; then
      echo "$output" >&2
      return 1
    fi
  done < <(arbor_signed_code "$app")
  codesign --verify --deep --strict "$app"
}
