# syntax=docker/dockerfile:1.6
FROM gmag11/metatrader5_vnc:latest

LABEL maintainer="alexpargon"
LABEL description="MT5 + Python 3.11 + followerBot dependencies (Wine)"
LABEL version="2.0.1"

# ---------------------------------------------------------------------------
# 1. Descargar instalador de Python 3.11 (operación como root, sin Wine)
# ---------------------------------------------------------------------------
USER root
ARG PYTHON_VERSION=3.11.9
ARG PYTHON_INSTALLER=python-${PYTHON_VERSION}-amd64.exe

RUN curl -fsSL "https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_INSTALLER}" \
        -o /tmp/${PYTHON_INSTALLER} \
 && chmod +x /tmp/${PYTHON_INSTALLER}

# ---------------------------------------------------------------------------
# 2. Preparar directorio /config (montable como volumen en runtime)
# ---------------------------------------------------------------------------
RUN mkdir -p /config && chown -R abc:abc /config

# ---------------------------------------------------------------------------
# 3. Entorno requerido por Wine en builds no interactivos
# ---------------------------------------------------------------------------
USER abc
ENV HOME=/config \
    WINEDEBUG=-all \
    DISPLAY=:0 \
    XDG_RUNTIME_DIR=/tmp/runtime-abc \
    WINEPREFIX=/config/.wine

RUN mkdir -p /tmp/runtime-abc && chmod 700 /tmp/runtime-abc

# ---------------------------------------------------------------------------
# 4. Inicializar wineprefix de forma controlada
# ---------------------------------------------------------------------------
RUN wineboot --init && wineserver -w

# ---------------------------------------------------------------------------
# 5. Instalar Python 3.11 dentro del wineprefix
#     - Se usa ';' en vez de '&&' porque el instalador /quiet puede devolver
#       códigos de salida distintos de 0 aún habiendo instalado correctamente.
#     - La verificación posterior con --version es la prueba real de éxito.
# ---------------------------------------------------------------------------
RUN wine /tmp/${PYTHON_INSTALLER} /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 \
    ; sleep 5 \
    ; wineserver -w \
    ; rm -f /tmp/${PYTHON_INSTALLER} \
    ; true

# ---------------------------------------------------------------------------
# 6. Verificar instalación de Python (intentando ambas rutas)
#     - Si el instalador es 64-bit, queda en Program Files
#     - Si el wineprefix es 32-bit, queda en Program Files (x86)
#     - Falla el build aquí si ninguna ruta tiene Python funcional
# ---------------------------------------------------------------------------
RUN if wine "C:\\Program Files\\Python311\\python.exe" --version 2>/dev/null; then \
        echo "Python 64-bit OK" ; \
    elif wine "C:\\Program Files (x86)\\Python311\\python.exe" --version 2>/dev/null; then \
        echo "Python 32-bit OK" ; \
    else \
        echo "ERROR: Python no se instaló en ninguna ruta esperada" ; \
        ls -la "/config/.wine/drive_c/Program Files/" 2>/dev/null || true ; \
        ls -la "/config/.wine/drive_c/Program Files (x86)/" 2>/dev/null || true ; \
        exit 1 ; \
    fi

# ---------------------------------------------------------------------------
# 7. Instalar dependencias del bot
#     - El archivo requirements.lock.txt está en la raíz del contexto de build
# ---------------------------------------------------------------------------
COPY --chown=abc:abc requirements.lock.txt /tmp/requirements.lock.txt

RUN if [ -f "/config/.wine/drive_c/Program Files/Python311/python.exe" ]; then \
        PY="C:\\Program Files\\Python311\\python.exe" ; \
    else \
        PY="C:\\Program Files (x86)\\Python311\\python.exe" ; \
    fi \
 && wine "$PY" -m pip install --upgrade pip \
 && wine "$PY" -m pip install -r /tmp/requirements.lock.txt \
 && wineserver -w \
 && rm /tmp/requirements.lock.txt

# ---------------------------------------------------------------------------
# 8. Servicio s6 que supervisa main.py
# ---------------------------------------------------------------------------
USER root
COPY s6/followerbot /etc/services.d/followerbot
RUN chmod +x /etc/services.d/followerbot/run /etc/services.d/followerbot/finish

# ---------------------------------------------------------------------------
# 9. Variables de entorno del bot
#     - BOT_PYTHON apunta a la ruta del Python instalado. Se resuelve
#       dinámicamente en el s6 run script para soportar 32 y 64 bit.
# ---------------------------------------------------------------------------
ENV BOT_DATA_DIR=/config/bot-data \
    BOT_CODE_DIR=/config/mi_trading_bot

# ---------------------------------------------------------------------------
# 10. Directorio persistente del estado del bot
# ---------------------------------------------------------------------------
RUN mkdir -p /config/bot-data && chown -R abc:abc /config/bot-data

USER abc
