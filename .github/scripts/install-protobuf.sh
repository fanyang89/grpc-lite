#!/usr/bin/env bash
set -euo pipefail

# Hosted runners can lack Ubuntu sources. Scope this list to these apt calls.
. /etc/os-release
case "$(dpkg --print-architecture)" in
    amd64) archive=https://archive.ubuntu.com/ubuntu; security=https://security.ubuntu.com/ubuntu ;;
    arm64) archive=https://ports.ubuntu.com/ubuntu-ports; security=$archive ;;
    *) echo "Unsupported Ubuntu runner architecture" >&2; exit 1 ;;
esac

sources=$(mktemp --suffix=.list)
trap 'rm -f "$sources"' EXIT
key='signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg'
cat > "$sources" <<EOF
deb [$key] $archive $VERSION_CODENAME main universe
deb [$key] $archive $VERSION_CODENAME-updates main universe
deb [$key] $security $VERSION_CODENAME-security main universe
EOF

apt_options=(-o "Dir::Etc::sourcelist=$sources" -o Dir::Etc::sourceparts=- -o Acquire::Retries=3)
apt-get "${apt_options[@]}" update --error-on=any --no-list-cleanup
apt-get "${apt_options[@]}" install -y --no-install-recommends protobuf-compiler libprotobuf-dev
