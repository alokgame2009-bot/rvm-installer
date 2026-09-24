# RVM Panel — SkylerNodes VPS Installer

This package turns the RVM/KVM Panel project into a VPS installer suitable for publishing to GitHub.

## GitHub one-command installation

After uploading this folder to your GitHub repository, run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR-USER/YOUR-REPO/main/install-github.sh)
```

The installer asks for:
- GitHub repository URL
- Panel domain (default: `rvm.skylernodes.fun`)
- Panel port (default: `3000`)
- Optional Cloudflare API token

It then installs Node.js 20+, npm, Git and Nginx, clones the project, builds Next.js, creates a systemd service, configures Nginx and optionally creates/updates a Cloudflare proxied A record.

## Cloudflare permissions

Use a Cloudflare API token with the minimum required DNS permission:
- Zone: Read
- DNS: Edit

The token is entered interactively and is not written to the project files.

The Cloudflare step only configures DNS. It does **not** automatically enable Cloudflare Tunnel/Zero Trust.

## Important

The domain must belong to a Cloudflare zone in the account used by the API token. `rvm.skylernodes.fun` should resolve to the VPS public IPv4 after the DNS record is created.

The current panel frontend is a starter UI. Real KVM/SSH provisioning still requires a trusted backend connected to libvirt, Proxmox, Incus or another virtualization system.
