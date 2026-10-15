#!/usr/bin/env bash
set -euo pipefail

sqlite_version() {
  php -r 'if (extension_loaded("pdo_sqlite")) { echo (new PDO("sqlite::memory:"))->query("SELECT sqlite_version()")->fetchColumn(); } elseif (extension_loaded("sqlite3")) { echo SQLite3::version()["versionString"]; }'
}

current_version=$(sqlite_version)
if [[ -z "$current_version" ]]; then
  echo 'SQLite extensions are disabled; keeping the PHP runtime unchanged.'
  exit 0
fi

echo "PHP SQLite runtime: $current_version"
if php -r 'exit(version_compare($argv[1], "3.46.0", ">=") ? 0 : 1);' "$current_version"; then
  echo 'SQLite already supports deeply nested queries; no download needed.'
  exit 0
fi

source /etc/os-release
if [[ "$ID" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
  echo 'The prebuilt SQLite runtime targets Ubuntu 24.04; keeping this runner unchanged.'
  exit 0
fi

if ! patcher=$(command -v patchelf); then
  echo 'patchelf is required to update only the PHP SQLite extensions.' >&2
  exit 1
fi

architecture=$(dpkg --print-architecture)
case "$architecture" in
  amd64)
    checksum=ff4b5a1e7c028a4bcc30076e4d8197aad1a910df44f4dc8dcf253e9ee9a3a367
    library_directory=x86_64-linux-gnu
    ;;
  arm64)
    checksum=c79eb1e82eeb3509af1a9792a5758ff3c4fed4b69bc8cd7c5871adafc30c19a9
    library_directory=aarch64-linux-gnu
    ;;
  *) echo "Unsupported SQLite architecture: $architecture" >&2; exit 1 ;;
esac

# SQLite 3.46 removes the parser stack limit; use Ubuntu's compatible prebuilt library.
started_at=${EPOCHREALTIME/./}
runtime_directory=$(mktemp -d "$RUNNER_TEMP/php-sqlite.XXXXXX")
package="$runtime_directory/sqlite.deb"
package_path="pool/main/s/sqlite3/libsqlite3-0_3.46.1-9ubuntu0.3_${architecture}.deb"
curl_options=(--fail --silent --show-error --location --retry 1 --connect-timeout 3 --max-time 15 --output "$package")
curl "${curl_options[@]}" "https://security.ubuntu.com/ubuntu/$package_path" ||
  curl "${curl_options[@]}" "http://azure.archive.ubuntu.com/ubuntu/$package_path"
echo "$checksum  $package" | sha256sum --check
dpkg-deb --extract "$package" "$runtime_directory"

extension_directory=$(php -r 'echo ini_get("extension_dir");')
enabled_extensions=$(php -r 'foreach (["pdo_sqlite", "sqlite3"] as $extension) { if (extension_loaded($extension)) { echo $extension, PHP_EOL; } }')
for extension in $enabled_extensions; do
  extension_path="$extension_directory/$extension.so"
  if [[ ! -f "$extension_path" ]]; then
    echo "Cannot locate the enabled PHP extension: $extension_path" >&2
    exit 1
  fi
  # Scope the library to PHP; loader environment variables also affect SQLite CLI and containers.
  sudo "$patcher" --replace-needed libsqlite3.so.0 \
    "$runtime_directory/usr/lib/$library_directory/libsqlite3.so.0" "$extension_path"
done
installed_version=$(sqlite_version)
if [[ "$installed_version" != 3.46.1 ]]; then
  echo "Expected PHP SQLite 3.46.1, got $installed_version" >&2
  exit 1
fi
elapsed_microseconds=$(( ${EPOCHREALTIME/./} - started_at ))
printf 'PHP SQLite runtime: %s; prebuilt setup took %d.%03d seconds.\n' \
  "$installed_version" "$((elapsed_microseconds / 1000000))" "$((elapsed_microseconds % 1000000 / 1000))"
