import { need, type Ops } from "./bridge-io.ts";
import { BridgeConnection } from "./bridge-connection.ts";

/**
 * Dictation: speak into the composer.
 *
 * Speech-to-TEXT only. The daemon also has a full duplex voice mode with
 * synthesised replies, and it is deliberately not wired up here -- an editor
 * that talks back needs an audio player, a way to interrupt it and somewhere
 * to put the transcript, which is a surface rather than a key.
 *
 * WHAT GOES OVER THE WIRE IS RAW PCM16, mono, base64, with the sample rate in
 * the format string -- the daemon parses it out with `/rate\s*=\s*(\d+)/` and
 * resamples from there. Not a container: there is no wav header, no webm, no
 * opus. `lua/paseo/voice.lua` is what produces that, because Neovim cannot
 * record audio and something has to shell out.
 *
 * Errors need no special handling. The daemon answers a bad start or a failed
 * transcription with `dictation_stream_error`, the client turns that into a
 * rejected promise, and `dispatch` turns a rejection into `{ok: false, error}`
 * -- which is exactly what the Lua needs to put the daemon's own sentence
 * ("speech models are not downloaded", say) in front of you.
 */
export function voiceOps(ctx: BridgeConnection): Ops {
  const raw = () => ctx.raw();
  return {
    async "dictation.start"(req) {
      await raw().startDictationStream(
        String(need(req.dictationId, "dictationId")),
        String(need(req.format, "format")),
      );
      return { started: true };
    },

    // Synchronous on the client -- a send, not a round trip -- so this returns
    // as soon as the bytes are on the socket. That matters: chunks arrive
    // every few hundred milliseconds for as long as you hold the key, and a
    // round trip each would put the queue behind the microphone.
    async "dictation.chunk"(req) {
      raw().sendDictationStreamChunk(
        String(need(req.dictationId, "dictationId")),
        Number(need(req.seq, "seq")),
        String(need(req.audio, "audio")),
        String(need(req.format, "format")),
      );
      return { seq: req.seq };
    },

    async "dictation.finish"(req) {
      const result = await raw().finishDictationStream(
        String(need(req.dictationId, "dictationId")),
        Number(need(req.finalSeq, "finalSeq")),
      );
      return { dictationId: result.dictationId, text: result.text ?? "" };
    },

    async "dictation.cancel"(req) {
      raw().cancelDictationStream(String(need(req.dictationId, "dictationId")));
      return { canceled: true };
    },
  };
}
