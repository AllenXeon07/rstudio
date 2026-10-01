FROM rocker/rstudio:latest

# Disable authentication entirely
ENV DISABLE_AUTH=true

# Set a custom password (alternative, use with DISABLE_AUTH=false)
ENV PASSWORD=""

# Expose the RStudio port
EXPOSE 8787
