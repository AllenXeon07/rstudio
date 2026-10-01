# RStudio Docker Container

A Dockerized RStudio server with configurable authentication.

## Quick Start

```bash
docker compose up -d --build
```

Access RStudio at `http://localhost:8787`

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RSTUDIO_AUTH_USER` | `admin` | Username for login |
| `RSTUDIO_AUTH_PASSWORD` | `admin123` | Password for login |
| `RSTUDIO_AUTH_ENABLED` | `true` | Enable/disable authentication |
| `RSTUDIO_SESSION_TIMEOUT_MINUTES` | `0` | Session timeout (0 = no timeout) |

### Dockerfile

- Based on `rocker/rstudio:latest`
- Exposes port 8787
- Configures RStudio authentication via environment variables
- Removes default `.Renviron.site` to allow custom config

### docker-compose.yml

Builds and runs the container with:
- Port mapping: `8787:8787`
- Volume mounts for `./data` and `./work` directories
- Restart policy: `unless-stopped`

---

## Usage

1. **Start the container:**
   ```bash
   docker compose up -d --build
   ```

2. **Access RStudio:**
   Open `http://localhost:8787` in your browser and log in with the configured credentials.

3. **Stop the container:**
   ```bash
   docker compose down
   ```

---

## Notes

- The `./data` volume persists RStudio data between restarts.
- The `./work` volume is used for temporary workspace files.
- To change the username/password, edit `docker-compose.yml` or rebuild with a custom `Dockerfile`.
