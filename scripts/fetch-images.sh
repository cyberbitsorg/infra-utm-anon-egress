#!/usr/bin/env bash
# Download the base images (Debian for the gateway, Kali for the workstation)
# and verify their checksums. Idempotent: skips work when a verified copy exists.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config
mkdir -p "$IMAGES_DIR"

# Verify <file> against a <sums_file> line matching <basename>, using SHA-<algo>
# (default 256). Handles the optional "*" binary marker in checksum files. The
# filename is compared as an exact field, not a regex, so metacharacters in the
# name (the dots in an image file name) can never match the wrong checksum line.
#
# The algo is a parameter because the two upstreams differ: Kali publishes
# SHA256SUMS, Debian's cloud image directory publishes SHA512SUMS only.
verify_file() {
  local file=$1 sums=$2 base=$3 algo="${4:-256}" expected actual
  [[ -f "$file" && -f "$sums" ]] || return 1
  expected="$(awk -v f="$base" '$2 == f || $2 == "*" f {print $1; exit}' "$sums")"
  [[ -n "$expected" ]] || return 1
  actual="$(shasum -a "$algo" "$file" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]]
}

fetch_debian() {
  local img sums base algo
  img="${IMAGES_DIR}/$(basename "$DEBIAN_IMG_URL")"
  base="$(basename "$DEBIAN_IMG_URL")"
  algo="${DEBIAN_SHA_ALGO:-512}"
  sums="${IMAGES_DIR}/debian-SHA${algo}SUMS"
  if verify_file "$img" "$sums" "$base" "$algo"; then
    ok "Debian image present and verified: ${img}"
    return
  fi
  log "Downloading Debian checksums"
  curl -fSL --retry 3 -o "$sums" "$DEBIAN_SHA_URL"
  log "Downloading Debian image (this can take a few minutes)"
  curl -fSL --retry 3 -o "$img" "$DEBIAN_IMG_URL"
  verify_file "$img" "$sums" "$base" "$algo" \
    || die "Checksum mismatch for ${base}. Delete images/ and retry."
  ok "Debian image verified: ${img}"
}

# Kali is distributed as an archive; the published SHA256SUMS covers that
# archive, not the raw disk we extract from it. So once extracted we record the
# raw disk's own checksum in a sidecar and re-check it on every later run --
# otherwise a truncated first extraction would be trusted forever (unlike the
# Debian image, whose upstream checksum re-verifies the file we actually keep).
fetch_kali() {
  local out sidecar archive sums base
  out="${IMAGES_DIR}/${KALI_IMG_FILE}"
  sidecar="${out}.sha256"
  if [[ -f "$out" ]]; then
    if [[ -f "$sidecar" ]] && shasum -a 256 -c "$sidecar" >/dev/null 2>&1; then
      ok "Kali image present and verified: ${out}"
      return
    fi
    if [[ ! -f "$sidecar" ]]; then
      # Image from before the sidecar existed: adopt it (trust on first use)
      # rather than force a ~25 GiB re-download, and verify it from here on.
      shasum -a 256 "$out" > "$sidecar"
      ok "Kali image present, recorded its checksum for future runs: ${out}"
      return
    fi
    warn "Kali image failed checksum verification, re-fetching: ${out}"
    rm -f "$out" "$sidecar"
  fi
  archive="${IMAGES_DIR}/$(basename "$KALI_IMG_URL")"
  sums="${IMAGES_DIR}/kali-SHA256SUMS"
  base="$(basename "$KALI_IMG_URL")"
  if ! verify_file "$archive" "$sums" "$base"; then
    log "Downloading Kali checksums"
    curl -fSL --retry 3 -o "$sums" "$KALI_SHA_URL" \
      || die "Could not fetch Kali SHA256SUMS for ${KALI_VERSION}. Check KALI_VERSION in lab.conf names a release still hosted at https://kali.download/cloud-images/ (very old releases move to https://old.kali.org/cloud-images/)."
    log "Downloading Kali image (large, this can take a while)"
    curl -fSL --retry 3 -o "$archive" "$KALI_IMG_URL" \
      || die "Could not download Kali ${KALI_VERSION} (${KALI_IMG_URL}). Check KALI_VERSION in lab.conf names a release still hosted at https://kali.download/cloud-images/ (very old releases move to https://old.kali.org/cloud-images/)."
    verify_file "$archive" "$sums" "$base" || die "Checksum mismatch for ${base}. Delete images/ and retry."
  fi
  log "Extracting Kali image"
  tar -xf "$archive" -C "$IMAGES_DIR"
  [[ -f "${IMAGES_DIR}/disk.raw" ]] || die "Kali archive did not contain the expected disk.raw"
  mv -f "${IMAGES_DIR}/disk.raw" "$out"
  rm -f "$archive"
  shasum -a 256 "$out" > "$sidecar"
  ok "Kali image ready: ${out}"
}

fetch_debian
fetch_kali
