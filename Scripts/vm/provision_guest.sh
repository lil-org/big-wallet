#!/bin/sh
set -eu

fail() { printf '%s\n' "Big Wallet VM setup: $*" >&2; exit 1; }

case "$(/usr/sbin/sysctl -n hw.model)" in
    VirtualMac*) ;;
    *) fail 'Refusing to provision outside a macOS virtual machine.' ;;
esac
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Run this one-time setup as root inside the guest.'
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'Usage: sudo sh provision_guest.sh /local/provision/config.json [--prepare-storage]'
mode=${2:-}
case "$mode" in ''|--prepare-storage) ;; *) fail 'Unknown provisioning mode.' ;; esac
[ -f "$1" ] && [ ! -L "$1" ] || fail 'A regular provisioning config.json is required.'
provision_directory=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd -P)
provision_config="$provision_directory/$(basename -- "$1")"
provision_module="$provision_directory/provision_guest.mjs"
[ -f "$provision_module" ] && [ ! -L "$provision_module" ] || fail 'A regular provisioning module is required.'
case "$provision_directory" in
    /private/tmp/big-wallet-provision.*/provision) [ "$mode" = --prepare-storage ] || fail 'Full provisioning requires the managed local staging directory.' ;;
    /Volumes/BigWalletBuild/Provisioning/*/provision) ;;
    *) fail 'Provisioning inputs must be staged locally inside the guest.' ;;
esac
for protected_path in "$provision_directory" "$(dirname -- "$provision_directory")"; do
    [ ! -L "$protected_path" ] && [ -d "$protected_path" ] || fail 'Local provisioning directories must be real directories.'
    [ "$(/usr/bin/stat -f '%u' "$protected_path")" -eq 0 ] || fail 'Local provisioning directories must be owned by root.'
    protected_mode=$(/usr/bin/stat -f '%Lp' "$protected_path")
    [ "$((0$protected_mode & 077))" -eq 0 ] || fail 'Local provisioning directories must be private.'
done
umask 022
[ "$(/usr/bin/plutil -extract version raw -o - "$provision_config")" = 1 ] || fail 'Unsupported provisioning config version.'
console_user=$(/usr/bin/plutil -extract consoleUser raw -o - "$provision_config")
case "$console_user" in ''|*[!a-zA-Z0-9_-]*) fail 'consoleUser must name an existing local account.' ;; esac
console_uid=$(/usr/bin/id -u "$console_user") || fail 'Create or select an existing guest account before setup.'
[ "$console_uid" -ge 500 ] || fail 'consoleUser must be a regular local account.'
console_gid=$(/usr/bin/id -g "$console_user")
vm_id=$(/usr/bin/plutil -extract vmId raw -o - "$provision_config")
case "$vm_id" in ''|*[!a-zA-Z0-9_-]*) fail 'vmId must contain only letters, digits, underscores, and hyphens.' ;; esac
node_version=24.22.0
npm_version=11.16.0
jq_version=1.8.1
jq_sha256=a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603
[ "$(/usr/bin/plutil -extract jq.version raw -o - "$provision_config")" = "$jq_version" ] || fail 'The pinned jq version is required.'
[ "$(/usr/bin/plutil -extract jq.sha256 raw -o - "$provision_config")" = "$jq_sha256" ] || fail 'The pinned official jq SHA-256 is required.'
case "$(/usr/bin/uname -m)" in arm64) node_arch=arm64 ;; *) fail 'An Apple silicon macOS guest is required.' ;; esac
unset NODE_OPTIONS NODE_PATH

temporary_directory=$(/usr/bin/mktemp -d /private/tmp/big-wallet-vm-setup.XXXXXX)
cleanup() { /bin/rm -rf "$temporary_directory"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
if [ ! -x /usr/local/bin/node ] || [ "$(/usr/local/bin/node --version)" != "v$node_version" ] ||
    [ ! -x /usr/local/bin/npm ] || ! /usr/local/bin/npm --version --cache "$temporary_directory/npm-cache" >/dev/null 2>&1; then
    printf '%s\n' "Installing Node $node_version from nodejs.org with SHA-256 verification."
    node_archive="node-v$node_version-darwin-$node_arch.tar.gz"
    node_url="https://nodejs.org/dist/v$node_version"
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$node_url/SHASUMS256.txt" -o "$temporary_directory/SHASUMS256.txt"
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$node_url/$node_archive" -o "$temporary_directory/$node_archive"
    /usr/bin/awk -v archive="$node_archive" '$2 == archive { print; found++ } END { if (found != 1) exit 1 }' \
        "$temporary_directory/SHASUMS256.txt" > "$temporary_directory/node.sha256" || fail 'Official Node checksum was not found.'
    (cd "$temporary_directory" && /usr/bin/shasum -a 256 -c node.sha256) || fail 'Node archive checksum did not match.'
    /bin/mkdir -p /usr/local
    /usr/bin/tar -xzf "$temporary_directory/$node_archive" -C /usr/local --strip-components=1
fi
if [ ! -x /usr/local/bin/npm ] || [ "$(/usr/local/bin/npm --version --cache "$temporary_directory/npm-cache")" != "$npm_version" ]; then
    printf '%s\n' "Installing npm $npm_version."
    /usr/local/bin/npm install --global --cache "$temporary_directory/npm-cache" --registry=https://registry.npmjs.org "npm@$npm_version" --no-audit --no-fund
fi
[ "$(/usr/local/bin/node --version)" = "v$node_version" ] || fail 'Node version verification failed.'
[ "$(/usr/local/bin/npm --version --cache "$temporary_directory/npm-cache")" = "$npm_version" ] || fail 'npm version verification failed.'
if [ ! -x /usr/local/bin/jq ] || [ "$(/usr/bin/shasum -a 256 /usr/local/bin/jq | /usr/bin/awk '{print $1}')" != "$jq_sha256" ]; then
    printf '%s\n' "Installing jq $jq_version with the pinned official SHA-256."
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://github.com/jqlang/jq/releases/download/jq-$jq_version/jq-macos-arm64" -o "$temporary_directory/jq"
    [ "$(/usr/bin/shasum -a 256 "$temporary_directory/jq" | /usr/bin/awk '{print $1}')" = "$jq_sha256" ] || fail 'jq binary checksum did not match.'
    /usr/bin/install -m 0755 "$temporary_directory/jq" /usr/local/bin/jq
fi
[ "$(/usr/local/bin/jq --version)" = "jq-$jq_version" ] || fail 'jq version verification failed.'

/usr/local/bin/node "$provision_module" "$provision_config" "$provision_directory" "$console_uid" "$console_gid" "$mode"
