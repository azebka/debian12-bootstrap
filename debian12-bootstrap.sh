#!/usr/bin/env bash
set -euo pipefail

# Comments/messages are in English by user preference.

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Run this script as root (or with sudo)." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  apt-get update -y
  apt-get install -y "$@"
}

ensure_packages() {
  local pkgs=()
  need_cmd whiptail || pkgs+=(whiptail)
  need_cmd ufw || pkgs+=(ufw)
  need_cmd sudo || pkgs+=(sudo)
  if ((${#pkgs[@]})); then
    apt_install "${pkgs[@]}"
  fi
}

trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }

is_valid_username() {
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

is_valid_ssh_pubkey() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[^[:space:]]+([[:space:]].*)?$ ]]
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

restart_sshd_safely() {
  if ! sshd -t; then
    echo "ERROR: sshd config test failed. Not restarting sshd." >&2
    return 1
  fi
  systemctl reload ssh || systemctl restart ssh
}

# --- UI helpers ---
msg() { whiptail --title "Debian 12 VPS Bootstrap" --msgbox "$1" 12 78; }
yesno() { whiptail --title "Debian 12 VPS Bootstrap" --yesno "$1" 12 78; }

inputbox() {
  local prompt="$1"; local def="${2:-}"
  whiptail --title "Debian 12 VPS Bootstrap" --inputbox "$prompt" 12 78 "$def" 3>&1 1>&2 2>&3
}

passwordbox() {
  local prompt="$1"
  whiptail --title "Debian 12 VPS Bootstrap" --passwordbox "$prompt" 12 78 3>&1 1>&2 2>&3
}

paste_key_from_terminal() {
  echo
  echo "=== SSH PUBLIC KEY INPUT (terminal mode) ==="
  echo "Paste your SSH PUBLIC key (single line) and press Enter:"
  echo "Example starts with: ssh-ed25519 AAAA..."
  echo
  local key=""
  IFS= read -r key </dev/tty || true
  echo "$key"
}

apply_relaxed_pw_policy() {
  # Relax password policy by note: this affects passwd/chpasswd system-wide (until you revert).
  local conf="/etc/security/pwquality.conf"
  backup_file "$conf"
  touch "$conf"

  # Remove existing keys we manage, then append our settings.
  sed -i -E '/^\s*(minlen|minclass|dictcheck|retry)\s*=/d' "$conf"

  cat >>"$conf" <<'EOF'

# --- Relaxed policy (managed by debian12-bootstrap.sh) ---
minlen = 6
minclass = 1
dictcheck = 0
retry = 3
EOF
}

set_user_password() {
  local user="$1"

  while true; do
    local p1 p2
    p1="$(passwordbox "Enter password for '$user':")"
    p2="$(passwordbox "Re-enter password:")"

    if [[ -z "$p1" || "$p1" != "$p2" ]]; then
      msg "Passwords do not match or are empty. Try again."
      continue
    fi

    if echo "$user:$p1" | chpasswd; then
      msg "Password updated for user '$user'."
      return 0
    fi

    msg "Password was rejected by system policy (pwquality).\n\nIf you want to bypass it, choose:\n- Relax password policy (at script start)\n- Or set a stronger password"

    if yesno "Try again with a stronger password?" ; then
      continue
    fi

    if yesno "Open interactive 'passwd $user' in terminal now?" ; then
      echo
      echo "Running: passwd $user"
      passwd "$user" </dev/tty
      msg "If passwd succeeded, you're done."
      return 0
    fi

    msg "Password was not changed."
    return 1
  done
}

# --- Main ---
ensure_packages

msg "This wizard will:\n\n- (Optionally) Relax password policy (pwquality)\n- Create/ensure a non-root sudo user\n- Set/change that user's password (optional)\n- Install your SSH public key\n- Disable SSH root login\n- Configure UFW firewall (optional Nginx)\n\nMake sure you can open a NEW SSH session after changes."

RELAX_PW="no"
if yesno "Relax password policy (pwquality) BEFORE user/password actions?\n\nThis disables dictionary checks and lowers requirements system-wide.\nRecommended only for initial setup." ; then
  RELAX_PW="yes"
  apply_relaxed_pw_policy
  msg "Relaxed password policy applied.\n\nNote: this is system-wide and stays until you revert /etc/security/pwquality.conf."
fi

# Username
USERNAME="$(inputbox "Enter the username (lowercase, e.g. 'az'):" "")"
USERNAME="$(echo "$USERNAME" | trim)"
if ! is_valid_username "$USERNAME"; then
  msg "Invalid username.\n\nRules: starts with a lowercase letter, then lowercase letters/digits/_- (max 32 chars)."
  exit 1
fi

USER_EXISTS="no"
if id "$USERNAME" >/dev/null 2>&1; then
  USER_EXISTS="yes"
  msg "User '$USERNAME' already exists.\nThe script can update password, sudo, SSH key, SSH settings, firewall."
fi

# Create user if needed
if [[ "$USER_EXISTS" == "no" ]]; then
  useradd -m -s /bin/bash "$USERNAME"
  msg "User '$USERNAME' created."
fi

# Password: allow setting/changing even if user exists
if yesno "Do you want to set/change the password for '$USERNAME' now?" ; then
  set_user_password "$USERNAME" || true
else
  msg "Skipping password setup.\n\nYou can set it later with:\n  sudo passwd $USERNAME"
fi

# Ensure sudo access
usermod -aG sudo "$USERNAME"
echo "%sudo ALL=(ALL:ALL) ALL" >/etc/sudoers.d/99-sudo-group
chmod 0440 /etc/sudoers.d/99-sudo-group

# SSH public key input method
KEY_INPUT_METHOD="$(whiptail --title "Debian 12 VPS Bootstrap" --menu \
"How do you want to provide the SSH public key?" 16 78 6 \
"dialog"   "Paste key in a whiptail dialog (single line)" \
"terminal" "Paste key in terminal (most reliable)" \
"file"     "Read key from a .pub file path" \
3>&1 1>&2 2>&3)"

SSH_PUBKEY=""
case "$KEY_INPUT_METHOD" in
  file)
    KEY_PATH="$(inputbox "Enter path to the public key file (e.g. /root/.ssh/id_ed25519.pub):" "/root/.ssh/id_ed25519.pub")"
    KEY_PATH="$(echo "$KEY_PATH" | trim)"
    if [[ ! -f "$KEY_PATH" ]]; then
      msg "File not found: $KEY_PATH"
      exit 1
    fi
    SSH_PUBKEY="$(head -n 1 "$KEY_PATH" | tr -d '\r' | trim)"
    ;;
  terminal)
    SSH_PUBKEY="$(paste_key_from_terminal | tr -d '\r' | trim)"
    ;;
  dialog|*)
    SSH_PUBKEY="$(inputbox "Paste your SSH PUBLIC key (single line):" "")"
    SSH_PUBKEY="$(echo "$SSH_PUBKEY" | tr -d '\r' | trim)"
    ;;
esac

if ! is_valid_ssh_pubkey "$SSH_PUBKEY"; then
  msg "The SSH public key doesn't look valid.\n\nExample:\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host"
  exit 1
fi

# Install key
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"
touch "$AUTH_KEYS"
chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if ! grep -Fqx "$SSH_PUBKEY" "$AUTH_KEYS"; then
  echo "$SSH_PUBKEY" >>"$AUTH_KEYS"
fi

# SSH port
SSH_PORT="$(inputbox "SSH port to use and allow in firewall (default 22):" "22")"
SSH_PORT="$(echo "$SSH_PORT" | trim)"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  msg "Invalid port."
  exit 1
fi

# PasswordAuthentication choice
DISABLE_PASSWORD_AUTH="yes"
if yesno "Disable SSH password authentication (recommended: key-only)?" ; then
  DISABLE_PASSWORD_AUTH="yes"
else
  DISABLE_PASSWORD_AUTH="no"
fi

# Nginx in firewall
ALLOW_NGINX="no"
if yesno "Allow Nginx (HTTP/HTTPS: 80 & 443) in firewall?" ; then
  ALLOW_NGINX="yes"
fi

# Summary
SUMMARY="Summary:\n\nRelax password policy: $RELAX_PW\nUser: $USERNAME (sudo)\nSSH key installed: yes\nSSH port: $SSH_PORT\nDisable root SSH login: yes\nDisable SSH password auth: $DISABLE_PASSWORD_AUTH\nAllow Nginx in firewall: $ALLOW_NGINX\nFirewall: UFW enable\n\nProceed?"
if ! whiptail --title "Debian 12 VPS Bootstrap" --yesno "$SUMMARY" 18 78; then
  msg "Cancelled.\nNo SSH/firewall changes were applied."
  exit 0
fi

# Configure SSH hardening via drop-in
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="$SSHD_DROPIN_DIR/99-bootstrap-hardening.conf"
install -d -m 755 "$SSHD_DROPIN_DIR"
backup_file "$SSHD_DROPIN_FILE"

{
  echo "# Managed by debian12-bootstrap.sh"
  echo "PermitRootLogin no"
  echo "PubkeyAuthentication yes"
  if [[ "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
  fi
  echo "Port $SSH_PORT"
} >"$SSHD_DROPIN_FILE"

chmod 644 "$SSHD_DROPIN_FILE"

# Restart SSH safely
if ! restart_sshd_safely; then
  msg "ERROR: sshd restart failed. Your SSH config may be invalid.\nThe script stopped to avoid locking you out."
  exit 1
fi

# Configure UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow "${SSH_PORT}/tcp"

# Nginx (HTTP/HTTPS)
if [[ "$ALLOW_NGINX" == "yes" ]]; then
  ufw allow 'Nginx Full'
fi

ufw --force enable

msg "Done.\n\nNEXT STEPS:\n1) Open a NEW terminal.\n2) SSH as: $USERNAME\n   ssh -p $SSH_PORT $USERNAME@YOUR_SERVER_IP\n3) Confirm sudo works: sudo -v\n\nRoot SSH login is disabled."

echo "All done."
