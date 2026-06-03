FROM lscr.io/linuxserver/beets:latest

# Enable Beets fingerprint matching via the chroma plugin.
# fpcalc is provided by chromaprint and is required for AcoustID/Chromaprint lookup.
RUN apk add --no-cache chromaprint
