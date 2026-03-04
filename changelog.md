# Changelog

## 2026-03-04

- Added `normalize_sshd_dropins()` so existing files in `/etc/ssh/sshd_config.d/*.conf` are rewritten before `99-bootstrap-hardening.conf` is applied. This makes `PermitRootLogin`, `PasswordAuthentication`, and `KbdInteractiveAuthentication` effective even when earlier drop-ins define them first.
- Added a menu to choose where the SSH key is installed: `root` (key-only root login) or a sudo user (create or reuse a non-root account).
- Added an option to disable timestamped `.bak.YYYYMMDD-HHMMSS` backups for config files during the current run.
- Changed UFW handling to add allow-rules without `ufw --force reset`; the script now enables UFW only when it is inactive.
