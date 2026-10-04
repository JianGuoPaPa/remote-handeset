ARG TARGETARCH
ARG BINARY_PATH=dist/webscreen-linux-${TARGETARCH}

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo adb xorg ffmpeg sway wf-recorder xfce4 xvfb seatd xwayland xterm udev xdotool

RUN useradd -m -s /bin/bash -G video,input appuser \
    && echo "appuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/appuser \
    && chmod 0440 /etc/sudoers.d/appuser

WORKDIR /app
COPY ./docker/full/entrypoint.sh /app/entrypoint.sh
ARG BINARY_PATH
COPY ${BINARY_PATH} /app/webscreen

RUN chmod +x /app/entrypoint.sh 
RUN chmod +x /app/webscreen

USER appuser
ENV PIN="123456"
ENV PORT=8079
EXPOSE $PORT

ENTRYPOINT ["/app/entrypoint.sh"]