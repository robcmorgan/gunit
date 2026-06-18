# Minimal Pode app container.
# Base: Microsoft's official PowerShell image (Debian-based, pwsh built in).
FROM mcr.microsoft.com/powershell:latest

# Install Pode once at build time so startup is instant.
# Pinned to a known-good version for reproducible builds — bump deliberately,
# don't let a rebuild silently pull a new major with breaking changes.
RUN pwsh -NoProfile -Command \
    "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
     Install-Module -Name Pode -RequiredVersion 2.13.2 -Scope AllUsers -Force"

WORKDIR /app
COPY UserDashboard.ps1 /app/UserDashboard.ps1

# Pode listens here (must match $Cfg.Port in the script).
EXPOSE 8080

# NOTE: the runtime user (2001:2002, to match the rest of the stack and the
# UMASK=002 file ownership) is set in docker-compose via `user:`, exactly like
# your recyclarr service. We deliberately do NOT bake a USER into the image so
# the same image can run under whatever uid:gid compose specifies.

ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/app/UserDashboard.ps1"]
