#!/bin/sh

set -eu

distribution_repository="${COMPARTMENT_RELEASES_REPOSITORY:-uibakery/compartment-cli}"
channel="latest"
version=""
bin_dir=""
init_install="0"
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
    --init-install)
      init_install="1"
      shift
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

can_use_installer_terminal() {
  (
    exec </dev/tty
  ) >/dev/null 2>&1
}

can_write_installer_terminal() {
  (
    exec >/dev/tty
  ) >/dev/null 2>&1
}

write_installer_terminal_prompt() {
  prompt_text="$1"
  if can_write_installer_terminal; then
    printf '%s' "$prompt_text" >/dev/tty
    return 0
  fi

  printf '%s' "$prompt_text" >&2
}

run_init_install() {
  init_install_path="$1"

  if ! can_use_installer_terminal; then
    printf 'Requested `--init-install`, but no terminal is available for sudo and setup prompts. Run `"%s" install` from an interactive shell.\n' "$init_install_path" >&2
    exit 1
  fi

  printf 'Running `"%s" install` for system on-prem setup.\n' "$init_install_path"
  if can_write_installer_terminal; then
    "$init_install_path" install </dev/tty >/dev/tty 2>/dev/tty
    return 0
  fi

  "$init_install_path" install </dev/tty
}

is_directory_on_path() {
  path_lookup_directory="$1"
  path_lookup_old_ifs="$IFS"
  IFS=:
  for path_lookup_entry in ${PATH:-}; do
    IFS="$path_lookup_old_ifs"
    if [ "$path_lookup_entry" = "$path_lookup_directory" ]; then
      return 0
    fi
    IFS=:
  done
  IFS="$path_lookup_old_ifs"

  return 1
}

is_user_bin_candidate() {
  user_bin_candidate_directory="$1"
  [ "$user_bin_candidate_directory" = "${HOME}/.local/bin" ] || [ "$user_bin_candidate_directory" = "${HOME}/bin" ]
}

is_usable_user_bin_directory() {
  usable_bin_candidate_directory="$1"
  if [ ! -e "$usable_bin_candidate_directory" ]; then
    return 0
  fi

  if [ ! -d "$usable_bin_candidate_directory" ] || [ ! -w "$usable_bin_candidate_directory" ]; then
    return 1
  fi

  if command -v find >/dev/null 2>&1; then
    usable_bin_owner_match="$(find "$usable_bin_candidate_directory" -prune -user "$(id -u)" -print 2>/dev/null || true)"
    [ -n "$usable_bin_owner_match" ]
    return $?
  fi

  return 0
}

select_user_bin_directory() {
  select_bin_old_ifs="$IFS"
  IFS=:
  for select_bin_path_entry in ${PATH:-}; do
    IFS="$select_bin_old_ifs"
    if is_user_bin_candidate "$select_bin_path_entry" && is_usable_user_bin_directory "$select_bin_path_entry"; then
      printf '%s' "$select_bin_path_entry"
      return 0
    fi
    IFS=:
  done
  IFS="$select_bin_old_ifs"

  printf '%s' "${HOME}/.local/bin"
}

read_shell_name() {
  shell_path="${SHELL:-}"
  printf '%s' "${shell_path##*/}"
}

read_shell_profile_path() {
  shell_name="$1"
  case "$shell_name" in
    zsh)
      printf '%s' "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    bash)
      printf '%s' "${HOME}/.bashrc"
      ;;
    fish)
      printf '%s' "${HOME}/.config/fish/config.fish"
      ;;
    *)
      printf ''
      ;;
  esac
}

build_path_update_command() {
  path_command_shell_name="$1"
  path_command_directory="$2"
  case "$path_command_shell_name" in
    fish)
      printf 'fish_add_path "%s"' "$path_command_directory"
      ;;
    *)
      printf 'export PATH="%s:$PATH"' "$path_command_directory"
      ;;
  esac
}

print_path_instruction() {
  instruction_path_directory="$1"
  instruction_shell_name="$2"
  instruction_path_command="$(build_path_update_command "$instruction_shell_name" "$instruction_path_directory")"
  printf '%s is not on PATH.\n' "$instruction_path_directory"
  printf 'Add it to your shell profile, or run for this shell: %s\n' "$instruction_path_command"
}

should_update_shell_profile() {
  prompt_path_directory="$1"
  prompt_profile_path="$2"

  if [ "${COMPARTMENT_INSTALLER_ACCEPT_PATH_UPDATE:-}" = "1" ]; then
    return 0
  fi

  if ! can_use_installer_terminal; then
    return 1
  fi

  write_installer_terminal_prompt "${prompt_path_directory} is not on PATH. Add it to ${prompt_profile_path}? [Y/n] "
  IFS= read -r answer </dev/tty || answer=""
  case "$answer" in
    ""|y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_path_update_if_missing() {
  append_profile_path="$1"
  append_path_command="$2"
  append_profile_directory="$(dirname "$append_profile_path")"

  mkdir -p "$append_profile_directory"
  if [ -f "$append_profile_path" ] && grep -F "$append_path_command" "$append_profile_path" >/dev/null 2>&1; then
    return 0
  fi

  {
    printf '\n'
    printf '# Add Compartment CLI to PATH\n'
    printf '%s\n' "$append_path_command"
  } >> "$append_profile_path"
}

ensure_bin_directory_on_path() {
  ensure_bin_directory="$1"
  if is_directory_on_path "$ensure_bin_directory"; then
    return 0
  fi

  ensure_shell_name="$(read_shell_name)"
  ensure_profile_path="$(read_shell_profile_path "$ensure_shell_name")"
  ensure_path_command="$(build_path_update_command "$ensure_shell_name" "$ensure_bin_directory")"

  if [ -z "$ensure_profile_path" ]; then
    print_path_instruction "$ensure_bin_directory" "$ensure_shell_name"
    return 0
  fi

  if should_update_shell_profile "$ensure_bin_directory" "$ensure_profile_path"; then
    append_path_update_if_missing "$ensure_profile_path" "$ensure_path_command"
    printf 'Added %s to %s. Restart your shell or run: %s\n' "$ensure_bin_directory" "$ensure_profile_path" "$ensure_path_command"
    return 0
  fi

  print_path_instruction "$ensure_bin_directory" "$ensure_shell_name"
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

if [ -z "$bin_dir" ]; then
  bin_dir="$(select_user_bin_directory)"
fi

mkdir -p "$bin_dir"
tar -xzf "$artifact_path" -C "$temp_directory"
install_path="${bin_dir}/compartment"
install -m 0755 "${temp_directory}/compartment" "$install_path"

printf 'Installed compartment to %s\n' "$install_path"
"$install_path" --version
ensure_bin_directory_on_path "$bin_dir"

if [ "$init_install" != "1" ]; then
  printf 'Installed CLI only. Run `"%s" install` when you are ready, or re-run this installer with `--init-install`.\n' "$install_path"
  exit 0
fi

run_init_install "$install_path"
