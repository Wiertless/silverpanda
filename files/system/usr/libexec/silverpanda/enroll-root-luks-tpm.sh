#!/usr/bin/bash
set -Eeuo pipefail

STATE_DIR=/var/lib/silverpanda
ATTEMPT_MARKER="$STATE_DIR/luks-tpm-enrollment-attempted"
mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"
# This is a once-per-installed-system boot-time offer. On failure/cancel, the
# user can rerun this script manually; we do not stall every future boot.
printf 'attempted %s\n' "$(date --iso-8601=seconds)" > "$ATTEMPT_MARKER"
chmod 0600 "$ATTEMPT_MARKER"

log() { printf 'Silverpanda LUKS TPM setup: %s\n' "$*"; }

if [[ ! -x /usr/bin/systemd-cryptenroll || ! -x /usr/bin/cryptsetup || ! -x /usr/bin/rpm-ostree ]]; then
  log 'required system tools are missing; no changes were made.'
  exit 0
fi

if [[ ! -e /dev/tpmrm0 ]]; then
  log 'no TPM2 resource-manager device (/dev/tpmrm0) was found; skipping.'
  exit 0
fi
if ! /usr/bin/mokutil --sb-state 2>&1 | /usr/bin/grep -qi 'SecureBoot enabled'; then
  log 'Secure Boot is not enabled; refusing automatic TPM enrollment.'
  exit 0
fi

# Walk only the block-device ancestry of /, and enroll the nearest LUKS2
# container that actually backs the root filesystem. Never guess another disk.
root_source=$(/usr/bin/findmnt --noheadings --output SOURCE --target / 2>/dev/null || true)
root_source=${root_source%%\[*}
if [[ -z "$root_source" || ! -e "$root_source" ]]; then
  log 'could not resolve the root filesystem block device; skipping.'
  exit 0
fi
root_source=$(/usr/bin/readlink -f -- "$root_source" 2>/dev/null || printf '%s' "$root_source")
luks_device=''
while IFS= read -r candidate; do
  [[ -b "$candidate" ]] || continue
  if /usr/bin/cryptsetup isLuks --type luks2 "$candidate" >/dev/null 2>&1; then
    luks_device=$candidate
    break
  fi
done < <(/usr/bin/lsblk --inverse --list --noheadings --paths --output NAME "$root_source" 2>/dev/null || true)

if [[ -z "$luks_device" ]]; then
  log 'the root filesystem is not backed by a discoverable LUKS2 container; nothing to do.'
  exit 0
fi

luks_uuid=$(/usr/bin/cryptsetup luksUUID "$luks_device")
if [[ ! "$luks_uuid" =~ ^[[:xdigit:]-]+$ ]]; then
  log 'could not read a valid LUKS UUID; refusing to modify kernel arguments.'
  exit 1
fi

has_tpm_token=false
if LC_ALL=C /usr/bin/systemd-cryptenroll "$luks_device" 2>/dev/null | /usr/bin/awk 'NR > 1 && $2 == "tpm2" { found=1 } END { exit !found }'; then
  has_tpm_token=true
fi

if [[ "$has_tpm_token" == true ]]; then
  prompt="TPM2 enrollment already exists for root LUKS device $luks_device. Type ENABLE to configure TPM-assisted root unlocking on future boots (anything else skips):"
else
  prompt="Silverpanda found root LUKS2 device $luks_device (UUID $luks_uuid). This adds a TPM2 keyslot and keeps all existing passphrases/recovery keys. Type ENROLL to continue (anything else skips):"
fi

confirmation=$(/usr/bin/systemd-ask-password --timeout=60 --echo=yes "$prompt") || {
  log 'confirmation was cancelled or timed out; no LUKS changes were made.'
  exit 0
}
if [[ "$has_tpm_token" == true && "$confirmation" != ENABLE ]]; then
  log 'TPM boot configuration skipped by user; no changes were made.'
  exit 0
elif [[ "$has_tpm_token" != true && "$confirmation" != ENROLL ]]; then
  log 'TPM enrollment skipped by user; no changes were made.'
  exit 0
fi

if [[ "$has_tpm_token" != true ]]; then
  passphrase=$(/usr/bin/systemd-ask-password --timeout=90 "Enter the existing LUKS passphrase for $luks_device. The passphrase is not saved by this script:") || {
    log 'passphrase prompt was cancelled or timed out; no LUKS changes were made.'
    exit 1
  }
  # Pass the secret on stdin only. It is not put in argv, the environment, or a file.
  if ! printf '%s\n' "$passphrase" | /usr/bin/systemd-cryptenroll \
      --tpm2-device=auto --tpm2-pcrs=7 "$luks_device"; then
    unset passphrase
    log 'systemd-cryptenroll failed; the existing passphrase remains the recovery path.'
    exit 1
  fi
  unset passphrase
  if ! LC_ALL=C /usr/bin/systemd-cryptenroll "$luks_device" 2>/dev/null | /usr/bin/awk 'NR > 1 && $2 == "tpm2" { found=1 } END { exit !found }'; then
    log 'TPM2 token verification failed. No kernel argument was added.'
    exit 1
  fi
fi

# Preserve existing rd.luks.options settings. Device-specific options replace
# global options, so merge the global list when creating a device-specific one.
current_kargs=$(/usr/bin/rpm-ostree kargs | /usr/bin/tail -n 1)
read -r -a karg_array <<< "$current_kargs"
specific_opts=''
global_opts=''
specific_count=0
for arg in "${karg_array[@]}"; do
  case "$arg" in
    rd.luks.options=*)
      value=${arg#rd.luks.options=}
      if [[ "$value" == "$luks_uuid"=* ]]; then
        specific_opts=${value#*=}
        specific_count=$((specific_count + 1))
      elif [[ ! "$value" =~ ^[[:xdigit:]-]{36}= ]]; then
        # It is not a UUID=value selector, so this is a global option list.
        # Global crypttab options may themselves contain '=' (for example
        # timeout=10), so do not use a generic contains-equals test here.
        global_opts=$value
      fi
      ;;
  esac
done

if (( specific_count > 1 )); then
  log 'multiple root-specific rd.luks.options arguments exist. The TPM2 keyslot is preserved, but kernel arguments need manual review.'
  exit 1
fi

if (( specific_count == 1 )); then
  if [[ ",$specific_opts," == *,tpm2-device=auto,* ]]; then
    log 'the root device already has tpm2-device=auto configured.'
  elif [[ "$specific_opts" == *tpm2-device=* ]]; then
    log "root device has a non-default TPM option ('$specific_opts'); refusing to override it. Review kernel arguments manually."
    exit 1
  else
    if [[ -n "$specific_opts" ]]; then
      new_opts="$specific_opts,tpm2-device=auto"
    else
      new_opts='tpm2-device=auto'
    fi
    old_arg="rd.luks.options=$luks_uuid=$specific_opts"
    new_arg="rd.luks.options=$luks_uuid=$new_opts"
    /usr/bin/rpm-ostree kargs --delete="$old_arg" --append="$new_arg"
  fi
else
  if [[ "$global_opts" == *tpm2-device=auto* ]]; then
    log 'a global rd.luks.options argument already enables TPM2 unlocking.'
  else
    new_opts='tpm2-device=auto'
    if [[ -n "$global_opts" ]]; then
      new_opts="$global_opts,$new_opts"
    fi
    /usr/bin/rpm-ostree kargs --append-if-missing="rd.luks.options=$luks_uuid=$new_opts"
  fi
fi

log "setup finished for root LUKS UUID $luks_uuid. Reboot to apply the staged kernel arguments; keep your passphrase/recovery key available until you've tested multiple boots."
