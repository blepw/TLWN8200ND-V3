#!/usr/bin/env bash

set -euo pipefail 


# vars 

BLACKLIST_FILE="/etc/modprobe.d/rtl8192eu-blacklist.conf"

REPO_URL="https://github.com/Mange/rtl8192eu-linux-driver"
REPO_DIR="rtl8192eu-linux-driver"
MODULE="rtl8192eu"
VERSION="1.0"

KEY_DIR="/root/mok-keys"
KEY_NAME="rtl8192eu"

KEY_PRIV="$KEY_DIR/$KEY_NAME.key"
KEY_PEM="$KEY_DIR/$KEY_NAME.pem"
KEY_DER="$KEY_DIR/$KEY_NAME.der"


# text 
info(){
  echo "[+] $1";
}

warn(){
  echo "[!] $1";
}

error(){
  echo "[✗] $1 ">&2;
}

banner(){  
              _            _
             /*\          /*\
             [-]          [-]
             [ ]          [ ]
             [ ]          [ ]
             [ ]          [ ]
             [ ]          [ ]
             [ ]          [ ]
             [ ]          [ ]
             [ ]          [ ]
             [ ]          [ ]
             [|]          [|]
            [ | ]        [ | ]
        ____|_|_|________|_|_|____
       |                          |
       |        RTL8192EU         |
       |                          |
       |           ...            |
       |        .. WPS ..         |
       |           ...            |
       |                          |
       |__________________________|
                 |-- --|
                 |-----|
                  |---|
                  ||-||
                  || || 
}



secure_boot_enabled(){
  # mokutil --sb-state 2>/dev/null 

  command -v mokutil >/dev/null 2>&1 || return 1 
  mokutil --sb-state 2>/dev/null | grep -q1 enabled 

}

ask_yes_no(){
  while true; do 
      read -rp "$1 [y/N]: " yn
      case "$yn" in
        [Yy]*) return 0;;
        [Nn]*|"") return 1ll
        *) echo "Please answee y or b" ;;
      esac
  done 
}


create_mok_key() {
  if [-f "$KEY_PRIV"] && p -f "$KEY_DER" ]; then
     info "MOK key already exists"
     return 
  fi 

  warn "Creating Machine Owner Key (MOK)"
  sudo mkdir -p "$KEY_DIR"
  sudo chmod 700 "$KEY_DIR"


  sudo openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$KEY_PRIV" \
        -out "$KEY_PEM" \
        -nodes \
        -days 36500 \
        -subj "/CN=RTL8192EU DKMS/"

  sudo openssl x509 -outform DER \
        -in "$KEY_PEM" \
        -out "$KEY_DER"

  sudo chmod 600 "$KEY_PRIV"
  info "MOK key created"

}

enroll_mok() {
    
    warn "You will be prompted to create a ONE-TIME password"
    warn "You MUST remember it for the reboot screen"

    sudo mokutil --import "$KEY_DER"

    # instruct 
    warn "After reboot:"
    warn " → Select 'Enroll MOK'"
    warn " → Enter the password"
    warn " → Reboot again"
}

sign_module(){
  local module_path

  module_path=$(modinfo -n "$MODULE" 2>/dev/null || true)
  if [ -z "$module_path" ]; then
      error "Module path not found for signing"
      return 1
  fi

  warn "Signing module: $module_path"

  sudo /usr/src/linux-headers-$(uname -r)/scripts/sign-file \
        sha256 \
        "$KEY_PRIV" \
        "$KEY_PEM" \
        "$module_path"

  info "Module signed successfully"
}

install_deps() {
    warn "Installing prerequisites"
    sudo apt-get update
    sudo apt-get install -y \
        git \
        dkms \
        build-essential \
        linux-headers-$(uname -r) \
        mokutil \
        openssl
}


blacklist_conflicts() {
      # write to blacklist 

    warn "Blacklisting conflicting drivers"    
    sudo tee "$BLACKLIST_FILE" >/dev/null <<EOF
blacklist rtl8xxxu
blacklist r8188eu
EOF
}

dkms_install() {
    # downloading driver from repo and installing module w dkms after build 
    if [ ! -d "$REPO_DIR" ]; then
        warn "Cloning repository"
        git clone "$REPO_URL"
    else
        info "Repository already exists"
    fi

    cd "$REPO_DIR"

    sudo mkdir -p /var/lib/dkms
    sudo chmod 755 /var/lib/dkms

    warn "Adding DKMS module"
    sudo dkms add . || true

    warn "Building module"
    sudo dkms build "$MODULE/$VERSION"

    warn "Installing module"
    sudo dkms install "$MODULE/$VERSION"
}

verify() {
    dkms status | grep -q "$MODULE, $VERSION.*installed" \
        && info "DKMS reports module installed" \
        || { error "DKMS install failed"; exit 1; }
}


if [[ "${1:-}" == "--uninstall" ]]; then
    uninstall_driver
    exit 0
fi


# run 

banner
install_deps
blacklist_conflicts
dkms_install
verify


# Secure Boot procedure 

if secure_boot_enabled; then
    warn "Secure Boot is ENABLED"

    if ask_yes_no "Do you want to sign the kernel module now?"; then
        create_mok_key
        enroll_mok
        sign_module

        warn "REBOOT REQUIRED"
        warn "Enroll the MOK key during boot"
    else
        warn "Module will NOT load unless Secure Boot is disabled"
    fi
else
    info "Secure Boot is disabled"
    sudo modprobe "$MODULE"
fi


info "Done"
warn "Plug the adapter and connect to Wi-Fi"

# eof ..
