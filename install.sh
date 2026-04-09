#!/bin/sh

set -eu

distribution_repository="${COMPARTMENT_RELEASES_REPOSITORY:-uibakery/compartment-cli}"
channel="latest"
version=""
bin_dir="${HOME}/.local/bin"
main_release_tag_asset="main-release-tag.txt"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel)
      channel="$2"
      shift 2
      ;;
    --version)
      version="$2"
      shift 2
      ;;
    --bin-dir)
      bin_dir="$2"
      shift 2
      ;;
    *)
      printf 'Unknown installer argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ -n "$version" ] && [ "$channel" != "latest" ]; then
  printf 'Choose either --version or --channel, not both.\n' >&2
  exit 1
fi

case "$channel" in
  latest|main)
    ;;
  *)
    printf 'Unsupported channel: %s\n' "$channel" >&2
    exit 1
    ;;
esac

resolve_main_release_tag() {
  main_release_tag_url="https://github.com/${distribution_repository}/releases/download/main/${main_release_tag_asset}"
  resolved_release_tag="$(curl -fsSL "$main_release_tag_url" | tr -d '\r\n')"

  if [ -z "$resolved_release_tag" ]; then
    printf 'Missing main release tag pointer in %s\n' "$main_release_tag_url" >&2
    exit 1
  fi

  case "$resolved_release_tag" in
    sha-*)
      printf 'Resolved main to %s\n' "$resolved_release_tag" >&2
      printf '%s' "$resolved_release_tag"
      ;;
    *)
      printf 'Invalid main release tag pointer: %s\n' "$resolved_release_tag" >&2
      exit 1
      ;;
  esac
}

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  darwin)
    target_os="darwin"
    ;;
  linux)
    target_os="linux"
    ;;
  *)
    printf 'Unsupported operating system: %s\n' "$os" >&2
    exit 1
    ;;
esac

case "$arch" in
  x86_64|amd64)
    target_arch="x64"
    ;;
  arm64|aarch64)
    target_arch="arm64"
    ;;
  *)
    printf 'Unsupported architecture: %s\n' "$arch" >&2
    exit 1
    ;;
esac

artifact_name="compartment-${target_os}-${target_arch}.tar.gz"

if [ -n "$version" ]; then
  case "$version" in
    main)
      resolved_release_tag="$(resolve_main_release_tag)"
      release_path="releases/download/${resolved_release_tag}"
      ;;
    sha-*)
      release_path="releases/download/${version}"
      ;;
    *)
      release_path="releases/download/v${version}"
      ;;
  esac
else
  if [ "$channel" = "main" ]; then
    resolved_release_tag="$(resolve_main_release_tag)"
    release_path="releases/download/${resolved_release_tag}"
  else
    release_path="releases/latest/download"
  fi
fi

base_url="https://github.com/${distribution_repository}/${release_path}"
artifact_url="${base_url}/${artifact_name}"
checksums_url="${base_url}/checksums.txt"

temp_directory="$(mktemp -d)"
trap 'rm -rf "$temp_directory"' EXIT INT TERM

artifact_path="${temp_directory}/${artifact_name}"
checksums_path="${temp_directory}/checksums.txt"

curl -fsSL -o "$artifact_path" "$artifact_url"
curl -fsSL -o "$checksums_path" "$checksums_url"

expected_checksum_line="$(awk -v target="$artifact_name" '$2 == target { print $0 }' "$checksums_path")"
if [ -z "$expected_checksum_line" ]; then
  printf 'Missing checksum entry for %s\n' "$artifact_name" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s\n' "$expected_checksum_line" | (cd "$temp_directory" && sha256sum -c -)
elif command -v shasum >/dev/null 2>&1; then
  expected_checksum="$(printf '%s\n' "$expected_checksum_line" | awk '{ print $1 }')"
  actual_checksum="$(shasum -a 256 "$artifact_path" | awk '{ print $1 }')"
  if [ "$actual_checksum" != "$expected_checksum" ]; then
    printf 'Checksum mismatch for %s\n' "$artifact_name" >&2
    exit 1
  fi
else
  printf 'Missing sha256 checksum tool.\n' >&2
  exit 1
fi

mkdir -p "$bin_dir"
tar -xzf "$artifact_path" -C "$temp_directory"
install -m 0755 "${temp_directory}/compartment" "${bin_dir}/compartment"

printf 'Installed compartment to %s\n' "${bin_dir}/compartment"
"${bin_dir}/compartment" --version
printf 'If you are upgrading an existing on-prem install, run `compartment update` from that install directory.\n'
