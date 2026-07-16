# YesNAS Installer

One-click installation, update, and uninstallation scripts for the complete YesNAS stack on Debian and Ubuntu.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/i-dj/yesnas-install/refs/heads/main/install.sh | bash
```

The installer asks for the device name (`yesnas` by default), Linux service user (the current user by default), and HTTP port (`80` by default, or `81` when port 80 is occupied). It installs YesNAS Server, verifies it, installs YesNAS Web, and configures Caddy.

After installation, open `http://yesnas` (or the selected device name). The default credentials are `admin` / `admin`; change the password after the first sign-in.

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/i-dj/yesnas-install/refs/heads/main/update.sh | bash
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/i-dj/yesnas-install/refs/heads/main/uninstall.sh | bash
```

The uninstaller keeps YesNAS data, shared system dependencies, and Caddy by default. Caddy may be used by other sites.

## Release

Run the **Release** workflow from the GitHub Actions page. Enter a semantic version such as `v1.2.3`, or leave the field empty to increment the latest patch version automatically.
