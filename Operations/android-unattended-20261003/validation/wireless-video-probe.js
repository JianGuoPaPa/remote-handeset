(async () => {
  const device = __DEVICE_ID_JSON__;
  if (location.origin !== 'http://127.0.0.1:8080' || !location.pathname.startsWith('/preview')) {
    throw new Error('unexpected_preview_origin');
  }
  const started = Date.now(), deadline = started + 22000;
  let pc, ws, video;
  let metadataReady = false, keyframeRequested = false;
  const errors = [], channels = [];
  const result = {device, connection: 'new', video: {}, controlChannels: [], errors};
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  try {
    window.handsetSevenProbe?.close();
    const response = await fetch('/preview/config', {cache: 'no-store', signal: AbortSignal.timeout(3000)});
    if (!response.ok) throw new Error('preview_config_http_' + response.status);
    const config = await response.json();
    Object.assign(config, {device_id: device, stream_profile: 'prewarm', preview_only: true});
    pc = new RTCPeerConnection({bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require', iceServers: []});
    pc.addTransceiver('video', {direction: 'recvonly'});
    pc.addTransceiver('audio', {direction: 'recvonly'});
    channels.push(pc.createDataChannel('control-ordered', {ordered: true}));
    channels.push(pc.createDataChannel('control-unordered', {ordered: false}));
    channels.push(pc.createDataChannel('control-transient', {ordered: false, maxRetransmits: 0}));
    // Keyframe request only; never send touch, key, clipboard or business input.
    const requestKeyframeOnceWhenReady = () => {
      if (metadataReady && !keyframeRequested && channels[0].readyState === 'open') {
        channels[0].send(new Uint8Array([0x10]));
        keyframeRequested = true;
      }
    };
    channels[0].onopen = requestKeyframeOnceWhenReady;
    video = document.createElement('video');
    video.autoplay = true; video.muted = true; video.playsInline = true;
    document.body.append(video);
    window.handsetSevenProbe = {close() { ws?.close(); pc?.close(); video?.remove(); }};
    pc.ontrack = event => {
      if (event.track.kind === 'video') {
        video.srcObject = event.streams[0] || new MediaStream([event.track]);
        video.play().catch(() => {});
      }
    };
    await pc.setLocalDescription(await pc.createOffer());
    if (pc.iceGatheringState !== 'complete') {
      await new Promise(resolve => {
        const done = () => { clearTimeout(timer); pc.removeEventListener('icegatheringstatechange', changed); resolve(); };
        const changed = () => { if (pc.iceGatheringState === 'complete') done(); };
        const timer = setTimeout(done, 2500);
        pc.addEventListener('icegatheringstatechange', changed);
      });
    }
    ws = new WebSocket('ws://127.0.0.1:8080/preview/ws');
    ws.onopen = () => ws.send(JSON.stringify({...config, sdp: pc.localDescription.sdp}));
    ws.onerror = () => errors.push('preview_websocket_error');
    ws.onmessage = async event => {
      try {
        const message = JSON.parse(event.data);
        if (message.status !== 'ok') { errors.push('gateway_' + (message.stage || 'error')); return; }
        if (message.stage === 'webrtc_init') {
          const sdp = message.sdp.replaceAll('\r\n', '\n').split('\n').filter(Boolean).join('\r\n') + '\r\n';
          await pc.setRemoteDescription({type: 'answer', sdp});
        }
        if (message.stage === 'webrtc_metainfo') {
          metadataReady = true;
          requestKeyframeOnceWhenReady();
        }
      } catch (_) { errors.push('signaling_response_invalid'); }
    };
    while (Date.now() < deadline) {
      await sleep(300);
      for (const stat of (await pc.getStats()).values()) {
        if (stat.type === 'inbound-rtp' && (stat.kind === 'video' || stat.mediaType === 'video')) {
          result.video = {framesDecoded: stat.framesDecoded || 0, framesReceived: stat.framesReceived || 0,
            width: stat.frameWidth || video.videoWidth, height: stat.frameHeight || video.videoHeight,
            bytesReceived: stat.bytesReceived || 0, packetsLost: stat.packetsLost || 0};
        }
      }
      result.connection = pc.connectionState;
      result.controlChannels = channels.map(channel => channel.readyState);
      if (errors.length || (result.video.framesDecoded >= 3 && result.video.width > 0 && result.video.height > 0
          && result.connection === 'connected' && result.controlChannels.every(state => state === 'open'))) break;
    }
  } catch (error) {
    errors.push(error instanceof Error ? error.name + ':' + error.message : 'probe_failed');
  } finally {
    result.elapsedMs = Date.now() - started;
    result.metadataReady = metadataReady;
    result.keyframeRequested = keyframeRequested;
    result.ok = errors.length === 0 && result.video.framesDecoded >= 3 && result.video.width > 0
      && result.video.height > 0 && result.connection === 'connected'
      && result.controlChannels.length === 3 && result.controlChannels.every(state => state === 'open');
    window.handsetSevenProbe?.close();
    ws?.close(); pc?.close(); video?.remove();
    window.handsetSevenProbe = null;
  }
  return result;
})()
