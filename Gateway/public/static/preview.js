(() => {
    "use strict";

    const video = document.getElementById("remoteVideo");
    const statusText = document.getElementById("statusText");
    const statusDot = document.getElementById("statusDot");
    const reconnectButton = document.getElementById("reconnectButton");

    let peerConnection = null;
    let signalingSocket = null;
    let orderedChannel = null;
    let reconnectTimer = null;
    let reconnectAttempt = 0;
    let connectionGeneration = 0;
    let attemptTimers = [];
    let mediaDeadline = null;

    function setStatus(text, state = "connecting") {
        statusText.textContent = text;
        statusDot.classList.toggle("connected", state === "connected");
        statusDot.classList.toggle("failed", state === "failed");
    }

    function closeConnection() {
        attemptTimers.forEach((timer) => window.clearTimeout(timer));
        attemptTimers = [];
        mediaDeadline = null;
        if (reconnectTimer !== null) {
            window.clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }
        if (signalingSocket !== null) {
            signalingSocket.onclose = null;
            signalingSocket.close();
            signalingSocket = null;
        }
        if (peerConnection !== null) {
            peerConnection.onconnectionstatechange = null;
            peerConnection.close();
            peerConnection = null;
        }
        orderedChannel = null;
        video.srcObject = null;
    }

    function armDeadline(generation, milliseconds, message) {
        const timer = window.setTimeout(() => {
            failAttempt(generation, message);
        }, milliseconds);
        attemptTimers.push(timer);
        return timer;
    }

    function clearDeadline(timer) {
        window.clearTimeout(timer);
        attemptTimers = attemptTimers.filter((item) => item !== timer);
    }

    function failAttempt(generation, message, error = null) {
        if (generation !== connectionGeneration) {
            return;
        }
        if (error !== null) {
            console.error(message, error);
        }
        closeConnection();
        setStatus(message, "failed");
        scheduleReconnect(generation);
    }

    function scheduleReconnect(generation) {
        if (generation !== connectionGeneration || reconnectTimer !== null) {
            return;
        }
        const delays = [800, 1800, 4000, 8000, 15000];
        const delay = delays[Math.min(reconnectAttempt, delays.length - 1)];
        reconnectAttempt += 1;
        setStatus("正在恢复连接");
        reconnectTimer = window.setTimeout(() => {
            reconnectTimer = null;
            connect();
        }, delay);
    }

    async function waitForIceGathering(pc) {
        if (pc.iceGatheringState === "complete") {
            return;
        }
        await new Promise((resolve) => {
            const timeout = window.setTimeout(resolve, 5000);
            pc.addEventListener("icegatheringstatechange", () => {
                if (pc.iceGatheringState === "complete") {
                    window.clearTimeout(timeout);
                    resolve();
                }
            });
        });
    }

    function normalizeSDP(sdp) {
        return sdp
            .replaceAll("\r\n", "\n")
            .split("\n")
            .filter((line) => line.length > 0)
            .join("\r\n") + "\r\n";
    }

    async function connect() {
        const generation = ++connectionGeneration;
        closeConnection();
        setStatus("正在连接");

        try {
            const answerDeadline = armDeadline(
                generation,
                12000,
                "信令连接超时"
            );
            const configResponse = await fetch("/preview/config", {
                cache: "no-store"
            });
            if (!configResponse.ok) {
                throw new Error(`config ${configResponse.status}`);
            }
            const config = await configResponse.json();

            const pc = new RTCPeerConnection({
                bundlePolicy: "max-bundle",
                rtcpMuxPolicy: "require"
            });
            peerConnection = pc;
            pc.addTransceiver("video", { direction: "recvonly" });
            orderedChannel = pc.createDataChannel("control-ordered", {
                ordered: true
            });
            pc.createDataChannel("control-unordered", { ordered: false });
            pc.createDataChannel("control-transient", {
                ordered: false,
                maxRetransmits: 0
            });

            pc.ontrack = (event) => {
                if (event.track.kind !== "video" || generation !== connectionGeneration) {
                    return;
                }
                video.srcObject = event.streams[0];
                video.addEventListener("playing", () => {
                    if (generation !== connectionGeneration) {
                        return;
                    }
                    if (mediaDeadline !== null) {
                        clearDeadline(mediaDeadline);
                        mediaDeadline = null;
                    }
                    reconnectAttempt = 0;
                    setStatus("本地直连", "connected");
                }, { once: true });
            };
            pc.onconnectionstatechange = () => {
                if (generation !== connectionGeneration) {
                    return;
                }
                if (pc.connectionState === "connected") {
                    setStatus("正在等待画面");
                    if (orderedChannel?.readyState === "open") {
                        orderedChannel.send(new Uint8Array([0x10]));
                    }
                } else if (
                    pc.connectionState === "failed" ||
                    pc.connectionState === "closed"
                ) {
                    scheduleReconnect(generation);
                } else if (pc.connectionState === "disconnected") {
                    window.setTimeout(() => {
                        if (
                            generation === connectionGeneration &&
                            pc.connectionState === "disconnected"
                        ) {
                            scheduleReconnect(generation);
                        }
                    }, 3000);
                }
            };

            const offer = await pc.createOffer({
                offerToReceiveVideo: true,
                offerToReceiveAudio: false
            });
            await pc.setLocalDescription(offer);
            await waitForIceGathering(pc);
            if (generation !== connectionGeneration) {
                return;
            }

            const socket = new WebSocket(
                `ws://${window.location.host}/preview/ws`
            );
            signalingSocket = socket;
            socket.onopen = () => {
                if (generation !== connectionGeneration) {
                    return;
                }
                socket.send(JSON.stringify({
                    ...config,
                    sdp: pc.localDescription.sdp
                }));
            };
            socket.onmessage = async (event) => {
                if (generation !== connectionGeneration) {
                    return;
                }
                try {
                    const message = JSON.parse(event.data);
                    if (message.status !== "ok") {
                        throw new Error(message.message || "gateway error");
                    }
                    if (message.stage === "webrtc_init") {
                        clearDeadline(answerDeadline);
                        if (mediaDeadline === null) {
                            mediaDeadline = armDeadline(
                                generation,
                                20000,
                                "等待画面超时"
                            );
                        }
                        const peerDeadline = armDeadline(
                            generation,
                            15000,
                            "WebRTC 连接超时"
                        );
                        await pc.setRemoteDescription({
                            type: "answer",
                            sdp: normalizeSDP(message.sdp)
                        });
                        const stateListener = () => {
                            if (pc.connectionState === "connected") {
                                clearDeadline(peerDeadline);
                                pc.removeEventListener(
                                    "connectionstatechange",
                                    stateListener
                                );
                            }
                        };
                        pc.addEventListener(
                            "connectionstatechange",
                            stateListener
                        );
                        stateListener();
                    }
                } catch (error) {
                    failAttempt(
                        generation,
                        "无法建立本地预览",
                        error
                    );
                }
            };
            socket.onerror = (error) => failAttempt(
                generation,
                "本地预览连接中断",
                error
            );
            socket.onclose = () => failAttempt(
                generation,
                "本地预览连接已关闭"
            );
        } catch (error) {
            failAttempt(generation, "连接失败", error);
        }
    }

    reconnectButton.addEventListener("click", () => {
        reconnectAttempt = 0;
        connect();
    });
    window.addEventListener("beforeunload", closeConnection);
    connect();
})();
