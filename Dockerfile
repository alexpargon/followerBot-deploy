# syntax=docker/dockerfile:1.6
FROM gmag11/metatrader5_vnc:latest

LABEL maintainer="alexpargon"
LABEL description="MT5 + Python 3.11 + followerBot dependencies (Wine)"
LABEL version="2.0"

USER root

# Python 3.11 instalador silencioso dentro de Wine
ARG PYTHON_VERSION=3.11.9
ARG PYTHON_INSTALLER=python-${PYTHON_VERSION}-amd64.exe

# 1. Descargar instalador de Python (host, no Wine aún)
RUN curl -fsSL "https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_INSTALLER}" \
  -o /tmp/${PYTHON_INSTALLER} \
  && chmod +x /tmp/${PYTHON_INSTALLER}

# 2. Instalar Python 3.11 dentro del wineprefix como usuario abc
RUN mkdir -p /config && chown -R abc:abc /config
USER abc
ENV HOME=/config
ENV WINEPREFIX=/config/.wine
RUN wine /tmp/${PYTHON_INSTALLER} /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 \
  && wineserver -w \
  && rm /tmp/${PYTHON_INSTALLER}

# 3. Actualizar pip e instalar dependencias del bot
COPY --chown=abc:abc requirements.lock.txt /tmp/requirements.lock.txt
RUN wine "C:\\Program Files\\Python311\\python.exe" -m pip install --upgrade pip \
  && wine "C:\\Program Files\\Python311\\python.exe" -m pip install -r /tmp/requirements.lock.txt \
  && wineserver -w \
  && rm /tmp/requirements.lock.txt

# 4. Servicio s6 para lanzar el bot
USER root
COPY s6/followerbot /etc/services.d/followerbot
RUN chmod +x /etc/services.d/followerbot/run /etc/services.d/followerbot/finish

# 5. Variables por defecto del bot
ENV BOT_DATA_DIR=/config/bot-data \
  BOT_CODE_DIR=/config/mi_trading_bot \
  BOT_PYTHON='C:\Program Files\Python311\python.exe'

# 6. Directorio de datos
RUN mkdir -p /config/bot-data && chown -R abc:abc /config/bot-data

USER abc
