#!/bin/bash

# This script is intended to be run by packer, inside an Ubuntu VM.
# It's purpose is to configure the VM for importing into google cloud,
# so that it will boot in GCE and be accessable for further use.

set -eo pipefail

SCRIPT_FILEPATH=$(realpath "${BASH_SOURCE[0]}")
SCRIPT_DIRPATH=$(dirname "$SCRIPT_FILEPATH")
REPO_DIRPATH=$(realpath "$SCRIPT_DIRPATH/../")

# Run as quickly as possible after boot
/bin/bash $REPO_DIRPATH/systemd_banish.sh

# shellcheck source=./lib.sh
source "$REPO_DIRPATH/lib.sh"

declare -a PKGS
PKGS=( \
    coreutils
    curl
    gawk
    git
    openssh-client
    openssh-server
    rng-tools5
    software-properties-common
)

$SUDO apt-get -qq -y update

# At the time of this commit, upgrading past the stock
# cloud-init (21.3-1-g6803368d-0ubuntu1~21.04.3) causes
# failure of login w/ new ssh key after reset + reboot.
if ! ((CONTAINER)); then
    $SUDO apt-mark hold cloud-init
fi

$SUDO apt-get -qq -y upgrade
$SUDO apt-get -qq -y install "${PKGS[@]}"

# compatibility / usefullness of all automated scripting (which is bash-centric)
$SUDO DEBCONF_DB_OVERRIDE='File{'$SCRIPT_DIRPATH/no_dash.dat'}' \
    dpkg-reconfigure dash

install_automation_tooling

if ! ((CONTAINER)); then
    custom_cloud_init
    $SUDO systemctl enable rngd
fi

finalize
