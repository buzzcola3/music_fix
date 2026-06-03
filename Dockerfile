FROM lscr.io/linuxserver/beets:latest

# Full fingerprint stack for Beets' chroma plugin:
# - chromaprint provides fpcalc
# - ffmpeg provides reliable audio decoding for downloaded media
# - pyacoustid lets Beets query AcoustID from Chromaprint fingerprints
RUN apk add --no-cache chromaprint ffmpeg py3-pip && \
    python3 -m pip install --no-cache-dir --break-system-packages pyacoustid
