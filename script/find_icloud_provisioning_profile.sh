#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${1:?usage: find_icloud_provisioning_profile.sh <bundle-id> <container-id>}"
CONTAINER_ID="${2:?usage: find_icloud_provisioning_profile.sh <bundle-id> <container-id>}"

best_profile=""
best_expiration=0
now=$(/bin/date -u +%s)

profile_directories=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)

for directory in "${profile_directories[@]}"; do
  [ -d "$directory" ] || continue

  while IFS= read -r -d '' candidate; do
    decoded_profile=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/openusage-profile.XXXXXX")
    if ! /usr/bin/security cms -D -i "$candidate" >"$decoded_profile" 2>/dev/null; then
      /bin/rm -f "$decoded_profile"
      continue
    fi

    application_identifier=$(/usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.application-identifier" \
      "$decoded_profile" 2>/dev/null || true)
    container_identifier=$(/usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.developer.ubiquity-container-identifiers:0" \
      "$decoded_profile" 2>/dev/null || true)
    expiration=$(/usr/bin/plutil -extract ExpirationDate raw -o - "$decoded_profile" 2>/dev/null || true)
    /bin/rm -f "$decoded_profile"

    case "$application_identifier" in
      *."$BUNDLE_ID") ;;
      *) continue ;;
    esac
    [ "$container_identifier" = "$CONTAINER_ID" ] || continue

    expiration_epoch=$(/bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expiration" +%s 2>/dev/null || true)
    [ -n "$expiration_epoch" ] || continue
    [ "$expiration_epoch" -gt "$now" ] || continue

    if [ "$expiration_epoch" -gt "$best_expiration" ]; then
      best_profile="$candidate"
      best_expiration="$expiration_epoch"
    fi
  done < <(/usr/bin/find "$directory" -type f \
    \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0)
done

[ -n "$best_profile" ] || exit 1
printf '%s\n' "$best_profile"
