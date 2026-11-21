import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { lookupUncachedUploadUrls } from "pretty-text/upload-short-url";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import { uploadVisualNotesBlob } from "../lib/npn-critique-reply-visual-notes";
import {
  formatVoiceNoteTime,
  isExtensionAuthorized,
  pickRecordingFormat,
  VOICE_NOTE_BITS_PER_SECOND,
  voiceNoteFilename,
} from "../lib/npn-critique-reply-voice-note";

const PHASE_IDLE = "idle";
const PHASE_REQUESTING = "requesting";
const PHASE_RECORDING = "recording";
const PHASE_UPLOADING = "uploading";

// Voice note recorder for the Critique Workspace (experimental spike).
//
// Records the microphone only — never the screen or camera — uploads the
// result through the standard uploads endpoint, and hands the upload to
// the parent via @onChange. The parent owns the recorded note
// (@voiceNote) and decides how it goes into the reply.
//
// Args:
//   @voiceNote   { uploadId, url, shortUrl, durationSeconds } | null
//   @onChange    (voiceNote | null) => void
//   @topicId     used only to name the uploaded file
//   @onRecordingStart  () => void — the take has started
//   @onRecordingStop   ({ discarded }) => object | null — the take has
//                ended; whatever it returns is merged into the note
//                handed to @onChange (the workspace uses this to attach
//                the pointer timeline it captured alongside the audio)
//   @capturesPointer   show the "your pointer is recorded too" hint
//   @disabled    true while the parent is posting
export default class NpnCritiqueVoiceRecorder extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked phase = PHASE_IDLE;
  @tracked elapsedSeconds = 0;
  @tracked errorMessage = null;
  // Playable URL resolved from a short URL when the note was restored
  // from a posted reply (which only carries `upload://…`).
  @tracked _resolvedUrl = null;
  _resolvedFor = null;

  _stream = null;
  _recorder = null;
  _chunks = [];
  _timer = null;
  _startedAt = 0;
  _discardOnStop = false;
  _takeOpen = false;
  _destroyed = false;

  willDestroy() {
    super.willDestroy(...arguments);
    this._destroyed = true;
    this._discardOnStop = true;
    this._teardownCapture();
  }

  get maxSeconds() {
    const configured = Number(
      this.siteSettings.npn_critique_reply_voice_note_max_seconds
    );
    return configured > 0 ? configured : 180;
  }

  get isIdle() {
    return this.phase === PHASE_IDLE;
  }

  get isRequesting() {
    return this.phase === PHASE_REQUESTING;
  }

  get isRecording() {
    return this.phase === PHASE_RECORDING;
  }

  get isUploading() {
    return this.phase === PHASE_UPLOADING;
  }

  get hasNote() {
    return this.isIdle && !!this.args.voiceNote;
  }

  get showRecordButton() {
    return this.isIdle && !this.args.voiceNote;
  }

  get recordingLabel() {
    return i18n("npn_critique_reply.modal.voice_note.recording", {
      elapsed: formatVoiceNoteTime(this.elapsedSeconds),
      max: formatVoiceNoteTime(this.maxSeconds),
    });
  }

  get playbackUrl() {
    const note = this.args.voiceNote;
    if (!note) {
      return null;
    }
    if (note.url) {
      return getURL(note.url);
    }
    if (note.shortUrl) {
      if (this._resolvedFor !== note.shortUrl) {
        this._resolveShortUrl(note.shortUrl);
      }
      return this._resolvedUrl;
    }
    return null;
  }

  // Restored notes only know their `upload://` short URL; ask core for
  // the real one so the preview player has something to load.
  async _resolveShortUrl(shortUrl) {
    this._resolvedFor = shortUrl;
    try {
      const uploads = await lookupUncachedUploadUrls([shortUrl], ajax);
      const url = uploads?.find((upload) => upload.short_url === shortUrl)
        ?.url;
      if (!this._destroyed && this._resolvedFor === shortUrl) {
        this._resolvedUrl = url ? getURL(url) : null;
      }
    } catch {
      // Preview only — the note is still attached and will post fine.
    }
  }

  @action
  async startRecording() {
    if (!this.isIdle || this.args.disabled) {
      return;
    }
    this.errorMessage = null;

    const format = navigator.mediaDevices?.getUserMedia
      ? pickRecordingFormat()
      : null;
    if (!format) {
      this.errorMessage = i18n(
        "npn_critique_reply.modal.voice_note.error_unsupported"
      );
      return;
    }
    // Fail before asking for the microphone, not after a three-minute
    // take, when the site would refuse the file anyway.
    if (
      !isExtensionAuthorized(
        format.extension,
        this.siteSettings,
        this.currentUser
      )
    ) {
      this.errorMessage = i18n(
        "npn_critique_reply.modal.voice_note.error_extension",
        { extension: format.extension }
      );
      return;
    }

    this.phase = PHASE_REQUESTING;
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true },
      });
    } catch (e) {
      if (!this._destroyed) {
        this.phase = PHASE_IDLE;
        this.errorMessage = this._captureErrorMessage(e);
      }
      return;
    }
    if (this._destroyed) {
      stream.getTracks().forEach((track) => track.stop());
      return;
    }

    try {
      this._stream = stream;
      this._chunks = [];
      this._discardOnStop = false;
      const recorder = new MediaRecorder(stream, {
        mimeType: format.mimeType,
        audioBitsPerSecond: VOICE_NOTE_BITS_PER_SECOND,
      });
      recorder.addEventListener("dataavailable", (event) => {
        if (event.data?.size) {
          this._chunks.push(event.data);
        }
      });
      recorder.addEventListener("stop", () => this._onRecorderStop(format));
      recorder.addEventListener("error", () => {
        this._discardOnStop = true;
        this._teardownCapture();
        if (!this._destroyed) {
          this.phase = PHASE_IDLE;
          this.errorMessage = i18n(
            "npn_critique_reply.modal.voice_note.error_generic"
          );
        }
      });
      this._recorder = recorder;
      recorder.start(1000);
      this._takeOpen = true;
      this.args.onRecordingStart?.();
    } catch {
      this._teardownCapture();
      this.phase = PHASE_IDLE;
      this.errorMessage = i18n(
        "npn_critique_reply.modal.voice_note.error_generic"
      );
      return;
    }

    this._startedAt = performance.now();
    this.elapsedSeconds = 0;
    this.phase = PHASE_RECORDING;
    this._timer = setInterval(() => this._tick(), 250);
  }

  @action
  stopRecording() {
    if (this._recorder && this._recorder.state !== "inactive") {
      this._recorder.stop();
    }
  }

  @action
  removeNote() {
    if (this.args.disabled) {
      return;
    }
    this.errorMessage = null;
    this.args.onChange?.(null);
  }

  @action
  async rerecord() {
    if (this.args.disabled) {
      return;
    }
    this.args.onChange?.(null);
    await this.startRecording();
  }

  _tick() {
    if (this._destroyed) {
      return;
    }
    const elapsed = (performance.now() - this._startedAt) / 1000;
    this.elapsedSeconds = Math.min(elapsed, this.maxSeconds);
    if (elapsed >= this.maxSeconds) {
      this.stopRecording();
    }
  }

  async _onRecorderStop(format) {
    const durationSeconds = Math.min(
      (performance.now() - this._startedAt) / 1000,
      this.maxSeconds
    );
    const chunks = this._chunks;
    const discard = this._discardOnStop || this._destroyed;
    const extra = this._endTake(discard);
    this._teardownCapture();
    if (discard) {
      return;
    }

    const blob = new Blob(chunks, { type: format.mimeType.split(";")[0] });
    if (!blob.size) {
      this.phase = PHASE_IDLE;
      this.errorMessage = i18n(
        "npn_critique_reply.modal.voice_note.error_empty"
      );
      return;
    }

    this.phase = PHASE_UPLOADING;
    try {
      const upload = await uploadVisualNotesBlob(
        blob,
        voiceNoteFilename(this.args.topicId, format.extension)
      );
      if (this._destroyed) {
        return;
      }
      this.args.onChange?.({
        ...extra,
        uploadId: upload?.id ?? null,
        url: upload?.url ?? null,
        shortUrl: upload?.short_url ?? null,
        durationSeconds: Math.round(durationSeconds),
      });
    } catch (e) {
      if (this._destroyed) {
        return;
      }
      this.errorMessage = i18n(
        "npn_critique_reply.modal.voice_note.error_upload",
        { detail: extractError(e, "") ?? "" }
      ).trim();
    } finally {
      if (!this._destroyed) {
        this.phase = PHASE_IDLE;
      }
    }
  }

  // Tell the parent the take is over, exactly once per take, and
  // collect whatever it wants attached to the note.
  _endTake(discarded) {
    if (!this._takeOpen) {
      return null;
    }
    this._takeOpen = false;
    try {
      return this.args.onRecordingStop?.({ discarded }) ?? null;
    } catch {
      return null;
    }
  }

  // Release the microphone (so the browser's recording indicator goes
  // away) and stop the timer. Safe to call repeatedly.
  _teardownCapture() {
    this._endTake(true);
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
    if (this._recorder && this._recorder.state !== "inactive") {
      try {
        this._recorder.stop();
      } catch {
        // Already stopping.
      }
    }
    this._recorder = null;
    this._stream?.getTracks().forEach((track) => track.stop());
    this._stream = null;
    this._chunks = [];
  }

  _captureErrorMessage(error) {
    const key =
      {
        NotAllowedError: "error_permission",
        SecurityError: "error_permission",
        NotFoundError: "error_no_microphone",
        OverconstrainedError: "error_no_microphone",
      }[error?.name] ?? "error_generic";
    return i18n(`npn_critique_reply.modal.voice_note.${key}`);
  }

  <template>
    <section class="npn-critique-voice-recorder" ...attributes>
      <div class="npn-critique-voice-recorder__header">
        <h4 class="npn-critique-voice-recorder__heading">
          {{i18n "npn_critique_reply.modal.voice_note.heading"}}
          <span class="npn-critique-voice-recorder__optional">
            {{i18n "npn_critique_reply.modal.voice_note.optional"}}
          </span>
        </h4>
      </div>

      {{#if this.showRecordButton}}
        <div class="npn-critique-voice-recorder__row">
          <DButton
            class="btn-default btn-small npn-critique-voice-recorder__record"
            @icon="microphone"
            @label="npn_critique_reply.modal.voice_note.record"
            @action={{this.startRecording}}
            @disabled={{@disabled}}
          />
          <span class="npn-critique-voice-recorder__helper">
            {{i18n "npn_critique_reply.modal.voice_note.helper"}}
          </span>
        </div>
      {{/if}}

      {{#if this.isRequesting}}
        <p class="npn-critique-voice-recorder__status" role="status">
          {{i18n "npn_critique_reply.modal.voice_note.requesting"}}
        </p>
      {{/if}}

      {{#if this.isRecording}}
        <div class="npn-critique-voice-recorder__row">
          <span class="npn-critique-voice-recorder__live" role="status">
            <span
              class="npn-critique-voice-recorder__dot"
              aria-hidden="true"
            ></span>
            {{this.recordingLabel}}
          </span>
          <DButton
            class="btn-danger btn-small npn-critique-voice-recorder__stop"
            @icon="stop"
            @label="npn_critique_reply.modal.voice_note.stop"
            @action={{this.stopRecording}}
          />
        </div>
        {{#if @capturesPointer}}
          <p class="npn-critique-voice-recorder__status">
            {{i18n "npn_critique_reply.modal.voice_note.pointer_hint"}}
          </p>
        {{/if}}
      {{/if}}

      {{#if this.isUploading}}
        <p class="npn-critique-voice-recorder__status" role="status">
          {{i18n "npn_critique_reply.modal.voice_note.uploading"}}
        </p>
      {{/if}}

      {{#if this.hasNote}}
        <div class="npn-critique-voice-recorder__row">
          {{#if this.playbackUrl}}
            <audio
              class="npn-critique-voice-recorder__player"
              controls
              preload="metadata"
              src={{this.playbackUrl}}
            ></audio>
          {{/if}}
          <DButton
            class="btn-flat btn-small npn-critique-voice-recorder__rerecord"
            @icon="microphone"
            @label="npn_critique_reply.modal.voice_note.rerecord"
            @action={{this.rerecord}}
            @disabled={{@disabled}}
          />
          <DButton
            class="btn-flat btn-small npn-critique-voice-recorder__remove"
            @icon="trash-can"
            @label="npn_critique_reply.modal.voice_note.remove"
            @action={{this.removeNote}}
            @disabled={{@disabled}}
          />
        </div>
      {{/if}}

      {{#if this.errorMessage}}
        <p class="npn-critique-voice-recorder__error" role="alert">
          {{this.errorMessage}}
        </p>
      {{/if}}
    </section>
  </template>
}
