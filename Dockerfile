# syntax=docker/dockerfile:1.6
FROM gmag11/metatrader5_vnc:latest

LABEL maintainer="alexpargon"
LABEL description="MT5 + Python 3.11 (embeddable) + followerBot dependencies (Wine)"
LABEL version="2.0.2"

# ---------------------------------------------------------------------------
# 1. Descargar Python 3.11 embeddable (zip, no instalador)
#    El embeddable es un Python self-contained sin instalador.
#    Usamos amd64 para máxima compatibilidad con MetaTrader5 actual.
# ---------------------------------------------------------------------------
USER root
ARG PYTHON_VERSION=3.11.9
ARG PYTHON_EMBED_ZIP=python-${PYTHON_VERSION}-embed-amd64.zip

RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_EMBED_ZIP}" \
        -o /tmp/${PYTHON_EMBED_ZIP}

# ---------------------------------------------------------------------------
# 2. Preparar /config y entorno de Wine
# ---------------------------------------------------------------------------
RUN mkdir -p /config && chown -R abc:abc /config

USER abc
ENV HOME=/config \
    WINEDEBUG=-all \
    DISPLAY=:0 \
    XDG_RUNTIME_DIR=/tmp/runtime-abc \
    WINEPREFIX=/config/.wine

RUN mkdir -p /tmp/runtime-abc && chmod 700 /tmp/runtime-abc

# ---------------------------------------------------------------------------
# 3. Inicializar wineprefix
# ---------------------------------------------------------------------------
RUN wineboot --init && wineserver -w

# ---------------------------------------------------------------------------
# 4. Extraer Python embeddable en C:\Python311 (dentro del wineprefix)
#    La ruta real en el filesystem Linux es /config/.wine/drive_c/Python311
# ---------------------------------------------------------------------------
USER root
RUN mkdir -p /config/.wine/drive_c/Python311 \
 && unzip -q /tmp/${PYTHON_EMBED_ZIP} -d /config/.wine/drive_c/Python311 \
 && rm /tmp/${PYTHON_EMBED_ZIP} \
 && chown -R abc:abc /config/.wine/drive_c/Python311

# ---------------------------------------------------------------------------
# 5. Habilitar 'site' module (necesario para pip)
#    El embeddable viene con 'import site' comentado en python311._pth.
#    Lo activamos para que pip y nuestras librerías funcionen.
# ---------------------------------------------------------------------------
USER abc
RUN sed -i 's|^#import site|import site|' /config/.wine/drive_c/Python311/python311._pth

# ---------------------------------------------------------------------------
# 6. Instalar pip dentro del Python embeddable
#    Descargamos get-pip.py oficial y lo ejecutamos con el python.exe de Wine.
# ---------------------------------------------------------------------------
USER root
RUN curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
 && chown abc:abc /tmp/get-pip.py

USER abc
RUN wine "C:\\Python311\\python.exe" /tmp/get-pip.py --no-warn-script-location \
    ; sleep 3 \
    ; wineserver -w \
    ; rm -f /tmp/get-pip.py \
    ; true

# ---------------------------------------------------------------------------
# 7. Verificar que python y pip funcionan
# ---------------------------------------------------------------------------
RUN wine "C:\\Python311\\python.exe" --version \
 && wine "C:\\Python311\\python.exe" -m pip --version

# ---------------------------------------------------------------------------
# 8. Instalar dependencias del bot
# ---------------------------------------------------------------------------
COPY --chown=abc:abc requirements.lock.txt /tmp/requirements.lock.txt

RUN wine "C:\\Python311\\python.exe" -m pip install --upgrade pip \
 && wine "C:\\Python311\\python.exe" -m pip install -r /tmp/requirements.lock.txt \
 && wineserver -w \
 && rm /tmp/requirements.lock.txt

# ---------------------------------------------------------------------------
# 9. Verificar que los imports críticos funcionan
# ---------------------------------------------------------------------------
RUN wine "C:\\Python311\\python.exe" -c "import MetaTrader5, telethon, dotenv, numpy; print('Imports OK:', MetaTrader5.__version__, telethon.__version__, numpy.__version__)"

# ---------------------------------------------------------------------------
# 10. Servicio s6
# ---------------------------------------------------------------------------
USER root
COPY s6/followerbot /etc/services.d/followerbot
RUN chmod +x /etc/services.d/followerbot/run /etc/services.d/followerbot/finish

# ---------------------------------------------------------------------------
# 11. Variables de entorno del bot
# ---------------------------------------------------------------------------
ENV BOT_DATA_DIR=/config/bot-data \
    BOT_CODE_DIR=/config/mi_trading_bot \
    BOT_PYTHON='C:\Python311\python.exe'

# ---------------------------------------------------------------------------
# 12. Directorio de estado
# ---------------------------------------------------------------------------
RUN mkdir -p /config/bot-data && chown -R abc:abc /config/bot-data

USER abc
