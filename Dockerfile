FROM lscr.io/linuxserver/beets:latest

# Enable Beets fingerprint matching via the chroma plugin.
# fpcalc is provided by chromaprint-tools and is required for AcoustID/Chromaprint lookup.
RUN apt-get update && \
    apt-get install -y --no-install-recommends chromaprint-tools && \
    rm -rf /var/lib/apt/lists/*
