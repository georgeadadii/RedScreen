import { MAX_FRAME_BYTES, ProtocolError } from './protocol';

/** Encodes one frame: a 4-byte big-endian length, then the payload. */
export function encodeFrame(payload: Buffer): Buffer {
  if (payload.length > MAX_FRAME_BYTES) throw new ProtocolError('oversized-message');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length);
  return Buffer.concat([header, payload]);
}

/**
 * Splits a byte stream into frames. A declared length above the limit fails immediately, before
 * buffering the payload, so a peer cannot make this side allocate large amounts of memory.
 */
export class FrameDecoder {
  private buffered = Buffer.alloc(0);

  push(chunk: Buffer): Buffer[] {
    this.buffered = Buffer.concat([this.buffered, chunk]);
    const frames: Buffer[] = [];
    while (this.buffered.length >= 4) {
      const length = this.buffered.readUInt32BE(0);
      if (length > MAX_FRAME_BYTES) throw new ProtocolError('oversized-message');
      if (this.buffered.length < 4 + length) break;
      frames.push(this.buffered.subarray(4, 4 + length));
      this.buffered = this.buffered.subarray(4 + length);
    }
    if (this.buffered.length > MAX_FRAME_BYTES + 4) throw new ProtocolError('oversized-message');
    return frames;
  }
}

/** Token bucket: at most `burst` messages at once, refilled at `perSecond`. */
export class RateLimiter {
  private tokens: number;
  private updatedAt: number;

  constructor(
    private readonly perSecond: number,
    private readonly burst: number,
    private readonly now: () => number = Date.now,
  ) {
    this.tokens = burst;
    this.updatedAt = now();
  }

  tryTake(): boolean {
    const current = this.now();
    this.tokens = Math.min(this.burst, this.tokens + ((current - this.updatedAt) / 1000) * this.perSecond);
    this.updatedAt = current;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}
