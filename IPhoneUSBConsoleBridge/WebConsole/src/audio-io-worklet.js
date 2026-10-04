const OUTPUT_BUFFER_SECONDS = 0.24;
const OUTPUT_START_SECONDS = 0.06;
const OUTPUT_RECOVERY_SECONDS = 0.08;
const MICROPHONE_PACKET_FRAMES = 960;

class PhoneAudioOutputProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = Math.max(2048, Math.ceil(sampleRate * OUTPUT_BUFFER_SECONDS));
    this.startThreshold = Math.max(128, Math.ceil(sampleRate * OUTPUT_START_SECONDS));
    this.recoveryTarget = Math.max(this.startThreshold, Math.ceil(sampleRate * OUTPUT_RECOVERY_SECONDS));
    this.channels = [new Float32Array(this.capacity), new Float32Array(this.capacity)];
    this.readIndex = 0;
    this.writeIndex = 0;
    this.available = 0;
    this.started = false;

    this.port.onmessage = ({ data }) => {
      if (data?.type === 'reset') {
        this.reset();
        return;
      }
      if (data?.type !== 'audio' || !Array.isArray(data.planes)) return;
      const planes = data.planes.map((buffer) => new Float32Array(buffer));
      const frames = Number.isInteger(data.frames) ? data.frames : planes[0]?.length;
      if (!frames || frames < 1 || planes.length < 1 || planes.some((plane) => plane.length < frames)) return;
      this.enqueue(planes, frames);
    };
  }

  reset() {
    this.readIndex = 0;
    this.writeIndex = 0;
    this.available = 0;
    this.started = false;
  }

  discard(frames) {
    const count = Math.min(Math.max(0, frames), this.available);
    this.readIndex = (this.readIndex + count) % this.capacity;
    this.available -= count;
  }

  enqueue(planes, frames) {
    let sourceOffset = 0;
    let frameCount = frames;
    if (frameCount >= this.capacity) {
      sourceOffset = frameCount - this.capacity;
      frameCount = this.capacity;
      this.reset();
    } else if (this.available + frameCount > this.capacity) {
      const retain = Math.min(this.available, this.recoveryTarget);
      this.discard(this.available - retain);
      if (this.available + frameCount > this.capacity) {
        this.discard(this.available + frameCount - this.capacity);
      }
      this.started = false;
    }

    for (let index = 0; index < frameCount; index += 1) {
      const destination = (this.writeIndex + index) % this.capacity;
      this.channels[0][destination] = planes[0][sourceOffset + index] ?? 0;
      const rightPlane = planes[Math.min(1, planes.length - 1)];
      this.channels[1][destination] = rightPlane[sourceOffset + index] ?? 0;
    }
    this.writeIndex = (this.writeIndex + frameCount) % this.capacity;
    this.available += frameCount;
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    const frameCount = output[0]?.length ?? 0;
    if (!frameCount) return true;

    if (!this.started) {
      if (this.available < this.startThreshold) return true;
      this.started = true;
    }
    if (this.available < frameCount) {
      this.started = false;
      return true;
    }

    for (let channel = 0; channel < output.length; channel += 1) {
      const source = this.channels[Math.min(channel, this.channels.length - 1)];
      const destination = output[channel];
      for (let index = 0; index < frameCount; index += 1) {
        destination[index] = source[(this.readIndex + index) % this.capacity];
      }
    }
    this.readIndex = (this.readIndex + frameCount) % this.capacity;
    this.available -= frameCount;
    return true;
  }
}

class ConsoleMicrophoneCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.active = false;
    this.packet = new Int16Array(MICROPHONE_PACKET_FRAMES);
    this.packetOffset = 0;

    this.port.onmessage = ({ data }) => {
      if (data?.type === 'start') {
        this.packetOffset = 0;
        this.active = true;
      } else if (data?.type === 'stop') {
        this.active = false;
        this.packetOffset = 0;
      }
    };
  }

  process(inputs, outputs) {
    const output = outputs[0];
    for (const channel of output) channel.fill(0);
    if (!this.active) return true;

    const input = inputs[0];
    const frameCount = input[0]?.length ?? 0;
    if (!frameCount || input.length < 1) return true;

    for (let frame = 0; frame < frameCount; frame += 1) {
      let sample = 0;
      for (let channel = 0; channel < input.length; channel += 1) {
        sample += input[channel][frame] ?? 0;
      }
      sample /= input.length;
      sample = Math.max(-1, Math.min(1, sample));
      this.packet[this.packetOffset] = sample < 0
        ? Math.round(sample * 32768)
        : Math.round(sample * 32767);
      this.packetOffset += 1;

      if (this.packetOffset === MICROPHONE_PACKET_FRAMES) {
        const completed = this.packet;
        this.packet = new Int16Array(MICROPHONE_PACKET_FRAMES);
        this.packetOffset = 0;
        this.port.postMessage({ type: 'microphoneData', pcm: completed.buffer }, [completed.buffer]);
      }
    }
    return true;
  }
}

registerProcessor('phone-audio-output', PhoneAudioOutputProcessor);
registerProcessor('console-microphone-capture', ConsoleMicrophoneCaptureProcessor);
