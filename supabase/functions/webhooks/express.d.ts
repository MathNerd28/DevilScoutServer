import type { Buffer } from "node:buffer";

declare global {
  namespace Express {
    interface Request {
      rawBody?: Buffer;
    }
  }
}
