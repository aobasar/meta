// Audio worklet for conversation mode: forwards the microphone's raw samples
// to the page in 20 ms frames (480 samples at 24 kHz).

const FRAME_SIZE = 480;

class PcmCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.frame = new Float32Array(FRAME_SIZE);
    this.filled = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (channel) {
      let offset = 0;
      while (offset < channel.length) {
        const take = Math.min(FRAME_SIZE - this.filled, channel.length - offset);
        this.frame.set(channel.subarray(offset, offset + take), this.filled);
        this.filled += take;
        offset += take;
        if (this.filled === FRAME_SIZE) {
          this.port.postMessage(this.frame);
          this.frame = new Float32Array(FRAME_SIZE);
          this.filled = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor("pcm-capture", PcmCapture);
