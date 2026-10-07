namespace Singularity.Apps.Voice {

    public const int RATE = 48000;
    public const int PEAKS_PER_SECOND = 20;

    public class InputDevice : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public Gst.Device? device { get; construct; }

        public InputDevice(string id, string label, Gst.Device? device) {
            Object(id: id, label: label, device: device);
        }
    }

    public class InputDevices : Object {
        public signal void changed();

        private Gst.DeviceMonitor monitor;
        private Gee.ArrayList<InputDevice> list = new Gee.ArrayList<InputDevice>();

        public InputDevices() {
            monitor = new Gst.DeviceMonitor();
            monitor.add_filter("Audio/Source", null);
            monitor.get_bus().add_watch(Priority.DEFAULT, (bus, message) => {
                if (message.type == Gst.MessageType.DEVICE_ADDED || message.type == Gst.MessageType.DEVICE_REMOVED) {
                    rebuild();
                    changed();
                }
                return true;
            });
            monitor.start();
            rebuild();
        }

        public void stop() {
            monitor.stop();
        }

        private void rebuild() {
            list.clear();
            list.add(new InputDevice("", _("System Default"), null));
            if (TestAudio.source() != null) list.add(new InputDevice("test", _("Test Input"), null));
            var seen = new Gee.HashSet<string>();
            foreach (var device in monitor.get_devices()) {
                string name = device.display_name;
                var props = device.properties;
                string? node = props != null ? props.get_string("node.name") : null;
                if (node == null && props != null) node = props.get_string("device.name");
                string id = node ?? name;
                if (props != null && props.has_field("device.class") && props.get_string("device.class") == "monitor") continue;
                if (seen.contains(id)) continue;
                seen.add(id);
                list.add(new InputDevice(id, name, device));
            }
        }

        public Gee.List<InputDevice> all() {
            return list.read_only_view;
        }

        public InputDevice find(string id) {
            foreach (var device in list) {
                if (device.id == id) return device;
            }
            return list[0];
        }
    }

    namespace TestAudio {
        public string? source() {
            string? value = Environment.get_variable("SINGULARITY_VOICE_TEST_INPUT");
            return value != null && value != "" ? value : null;
        }

        public Gst.Element make_sink() {
            if (source() != null) {
                var sink = Gst.ElementFactory.make("fakesink", null);
                sink.set("sync", true);
                return sink;
            }
            return Gst.ElementFactory.make("autoaudiosink", null);
        }
    }

    public enum RecorderState {
        IDLE,
        RECORDING,
        PAUSED,
        FINISHING
    }

    public class Recorder : Object {
        public RecorderState state { get; private set; default = RecorderState.IDLE; }
        public int64 elapsed { get; private set; default = 0; }
        public float level { get; private set; default = 0; }
        public string path { get; private set; default = ""; }

        public signal void peak(float value);
        public signal void finished(bool ok, string? error);

        private Gst.Pipeline? pipeline = null;
        private Gst.Pad? entry = null;
        private VoiceGateC.Gate? gate = null;
        private int64 paused_at = 0;
        private int64 paused_total = 0;
        private uint bus_watch = 0;
        private float[] peaks = {};
        private bool discard = false;

        public float[] take_peaks() {
            return peaks;
        }

        private Gst.Element make_source(InputDevice input) throws Error {
            string? test = TestAudio.source();
            if (input.id == "test" && test != null) {
                if (test == "tone") return Gst.parse_bin_from_description("audiotestsrc is-live=true wave=sine freq=330 volume=0.5", true);
                return file_source(test);
            }
            if (input.device != null) {
                var element = input.device.create_element(null);
                if (element != null) return element;
            }
            var auto = Gst.ElementFactory.make("autoaudiosrc", null);
            if (auto == null) throw new IOError.NOT_SUPPORTED(_("No audio input is available on this system"));
            return auto;
        }

        private static Gst.Element file_source(string path) throws Error {
            var bin = new Gst.Bin("voice-test-input");
            var file = Gst.ElementFactory.make("filesrc", null);
            var decode = Gst.ElementFactory.make("decodebin", null);
            var tail = Gst.parse_bin_from_description("audioconvert ! audioresample ! identity sync=true", true);
            file.set("location", path);
            bin.add_many(file, decode, tail);
            file.link(decode);
            decode.pad_added.connect((pad) => {
                var sink = tail.get_static_pad("sink");
                if (!sink.is_linked()) pad.link(sink);
            });
            bin.add_pad(new Gst.GhostPad("src", tail.get_static_pad("src")));
            return bin;
        }

        public void start(InputDevice input, string target) throws Error {
            if (state != RecorderState.IDLE) return;
            var source = make_source(input);
            var tail = Gst.parse_bin_from_description(
                "audioconvert ! audioresample ! audio/x-raw,rate=%d,channels=1 ! level name=meter interval=%lld post-messages=true ! %s ! filesink name=out".printf(
                    RATE, NS_PER_SECOND / PEAKS_PER_SECOND, ExportFormat.recording().chain), true);
            var bin = (Gst.Bin) tail;
            bin.get_by_name("out").set("location", target);
            pipeline = new Gst.Pipeline("voice-recorder");
            pipeline.add_many(source, tail);
            if (!source.link(tail)) throw new IOError.FAILED(_("The audio input cannot be used"));
            path = target;
            peaks = {};
            elapsed = 0;
            discard = false;
            bus_watch = pipeline.get_bus().add_watch(Priority.DEFAULT, on_message);
            if (pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                teardown();
                FileUtils.unlink(target);
                throw new IOError.FAILED(_("The audio input cannot be opened"));
            }
            entry = tail.get_static_pad("sink");
            gate = new VoiceGateC.Gate(entry);
            paused_total = 0;
            state = RecorderState.RECORDING;
        }

        private int64 running_time() {
            var clock = pipeline.get_clock();
            if (clock == null) return 0;
            return (int64) (clock.get_time() - pipeline.get_base_time());
        }

        public void pause() {
            if (state != RecorderState.RECORDING) return;
            paused_at = running_time();
            gate.set_paused(true);
            state = RecorderState.PAUSED;
            level = 0;
        }

        public void resume() {
            if (state != RecorderState.PAUSED) return;
            int64 gap = int64.max(running_time() - paused_at, 0);
            paused_total += gap;
            gate.add_offset(gap);
            gate.set_paused(false);
            state = RecorderState.RECORDING;
        }

        public void stop() {
            if (pipeline == null || state == RecorderState.FINISHING || state == RecorderState.IDLE) return;
            if (gate != null) gate.set_paused(false);
            state = RecorderState.FINISHING;
            entry.send_event(new Gst.Event.eos());
        }

        public void cancel() {
            if (pipeline == null) return;
            discard = true;
            string doomed = path;
            teardown();
            FileUtils.unlink(doomed);
            state = RecorderState.IDLE;
            finished(false, null);
        }

        private void teardown() {
            if (bus_watch != 0) Source.remove(bus_watch);
            bus_watch = 0;
            if (pipeline != null) pipeline.set_state(Gst.State.NULL);
            pipeline = null;
            gate = null;
            entry = null;
        }

        private bool on_message(Gst.Bus bus, Gst.Message message) {
            switch (message.type) {
            case Gst.MessageType.ELEMENT:
                unowned Gst.Structure? s = message.get_structure();
                if (s == null || s.get_name() != "level") break;
                if (state != RecorderState.RECORDING) break;
                uint64 running, duration;
                s.get_uint64("running-time", out running);
                s.get_uint64("duration", out duration);
                elapsed = (int64) (running + duration);
                unowned GLib.Value? value = s.get_value("peak");
                float top = 0;
                if (value != null) {
                    unowned GLib.ValueArray? values = (GLib.ValueArray?) value.get_boxed();
                    if (values != null) {
                        for (uint i = 0; i < values.n_values; i++) {
                            float v = Peaks.from_db(values.get_nth(i).get_double());
                            if (v > top) top = v;
                        }
                    }
                }
                peaks += top;
                level = top;
                peak(top);
                break;
            case Gst.MessageType.EOS:
                teardown();
                state = RecorderState.IDLE;
                if (!discard) finished(true, null);
                return false;
            case Gst.MessageType.ERROR:
                Error error;
                string debug;
                message.parse_error(out error, out debug);
                warning("Recorder: %s (%s)", error.message, debug ?? "");
                string doomed = path;
                teardown();
                if (elapsed < NS_PER_SECOND / 2) FileUtils.unlink(doomed);
                state = RecorderState.IDLE;
                finished(false, error.message);
                return false;
            default:
                break;
            }
            return true;
        }
    }

    public class TranscodeResult : Object {
        public bool ok;
        public string? error;
        public int64 duration;
        public float[] peaks;
    }

    public class Transcoder : Object {
        public signal void progress(double fraction);

        private Cancellable cancellable = new Cancellable();

        public void cancel() {
            cancellable.cancel();
        }

        public async TranscodeResult run(File source, string? target, ExportFormat? format, owned Span[] keep_ns, int64 source_duration) {
            var result = new TranscodeResult();
            SourceFunc callback = run.callback;
            new Thread<void>("voice-transcode", () => {
                work(source, target, format, keep_ns, source_duration, result);
                Idle.add((owned) callback);
            });
            yield;
            return result;
        }

        private void report(double fraction) {
            Idle.add(() => {
                progress(fraction);
                return Source.REMOVE;
            });
        }

        private void work(File source, string? target, ExportFormat? format, Span[] keep_ns, int64 source_duration, TranscodeResult result) {
            Gst.Pipeline? decode = null;
            Gst.Pipeline? encode = null;
            try {
                decode = (Gst.Pipeline) Gst.parse_launch(
                    "uridecodebin name=dec ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,layout=interleaved,rate=%d,channels=1 ! appsink name=sink sync=false".printf(RATE));
                ((Gst.Bin) decode).get_by_name("dec").set("uri", source.get_uri());
                var sink = (Gst.App.Sink) ((Gst.Bin) decode).get_by_name("sink");
                Gst.App.Src? src = null;
                if (target != null && format != null) {
                    encode = (Gst.Pipeline) Gst.parse_launch(
                        "appsrc name=src format=time ! %s ! filesink name=out".printf(format.chain));
                    src = (Gst.App.Src) ((Gst.Bin) encode).get_by_name("src");
                    src.caps = Gst.Caps.from_string("audio/x-raw,format=S16LE,layout=interleaved,rate=%d,channels=1".printf(RATE));
                    ((Gst.Bin) encode).get_by_name("out").set("location", target);
                    encode.set_state(Gst.State.PLAYING);
                }
                decode.set_state(Gst.State.PLAYING);

                Span[] keep = keep_ns.length > 0 ? Samples.spans_from_ns(keep_ns, RATE) : new Span[0];
                bool everything = keep_ns.length == 0;
                int64 total = everything ? Samples.from_ns(source_duration, RATE) : 0;
                foreach (var span in keep) total = int64.max(total, span.end);
                var builder = new PeakBuilder(RATE / PEAKS_PER_SECOND);
                int64 position = 0;
                int64 written = 0;
                double reported = -1;
                while (!cancellable.is_cancelled()) {
                    var sample = sink.try_pull_sample(100 * Gst.MSECOND);
                    if (sample == null) {
                        if (sink.is_eos()) break;
                        var failure = decode.get_bus().pop_filtered(Gst.MessageType.ERROR);
                        if (failure != null) {
                            Error error;
                            string debug;
                            failure.parse_error(out error, out debug);
                            throw error;
                        }
                        continue;
                    }
                    var buffer = sample.get_buffer();
                    Gst.MapInfo info;
                    if (!buffer.map(out info, Gst.MapFlags.READ)) continue;
                    int64 count = info.data.length / 2;
                    Span[] parts = everything ? new Span[] { Span(0, count) } : Samples.keep_in_chunk(keep, position, count);
                    foreach (var part in parts) {
                        int bytes = (int) (part.length() * 2);
                        var copy = new uint8[bytes];
                        Memory.copy(copy, (uint8*) info.data + part.start * 2, bytes);
                        var pcm = new int16[part.length()];
                        Memory.copy(pcm, copy, bytes);
                        builder.feed_s16(pcm);
                        if (src != null) {
                            var out_buffer = new Gst.Buffer.wrapped((owned) copy);
                            out_buffer.pts = Samples.to_ns(written, RATE);
                            out_buffer.duration = Samples.to_ns(written + part.length(), RATE) - out_buffer.pts;
                            src.push_buffer((owned) out_buffer);
                        }
                        written += part.length();
                    }
                    buffer.unmap(info);
                    position += count;
                    if (total > 0) {
                        double fraction = double.min(1.0, (double) position / total);
                        if (fraction - reported >= 0.02) {
                            reported = fraction;
                            report(fraction);
                        }
                    }
                    if (!everything && Samples.past_all(keep, position)) break;
                }
                decode.set_state(Gst.State.NULL);
                if (cancellable.is_cancelled()) {
                    if (encode != null) encode.set_state(Gst.State.NULL);
                    if (target != null) FileUtils.unlink(target);
                    result.ok = false;
                    result.error = null;
                    return;
                }
                if (src != null) {
                    src.end_of_stream();
                    var message = encode.get_bus().timed_pop_filtered(60 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR);
                    encode.set_state(Gst.State.NULL);
                    if (message == null || message.type == Gst.MessageType.ERROR) {
                        string text = _("The file could not be written");
                        if (message != null) {
                            Error error;
                            string debug;
                            message.parse_error(out error, out debug);
                            text = error.message;
                        }
                        if (target != null) FileUtils.unlink(target);
                        result.ok = false;
                        result.error = text;
                        return;
                    }
                }
                report(1.0);
                result.ok = true;
                result.duration = Samples.to_ns(written, RATE);
                result.peaks = builder.finish();
            } catch (Error e) {
                if (decode != null) decode.set_state(Gst.State.NULL);
                if (encode != null) encode.set_state(Gst.State.NULL);
                if (target != null) FileUtils.unlink(target);
                result.ok = false;
                result.error = e.message;
            }
        }
    }

    public class Player : Object {
        public bool playing { get; private set; default = false; }
        public double speed { get; private set; default = 1.0; }
        public int64 duration { get; private set; default = 0; }
        public string uri { get; private set; default = ""; }

        public signal void ended();

        private dynamic Gst.Element playbin;
        private int64 stop_at = -1;

        public Player() {
            playbin = Gst.ElementFactory.make("playbin", "voice-player");
            playbin.audio_sink = TestAudio.make_sink();
            var tempo = Gst.ElementFactory.make("scaletempo", null);
            if (tempo != null) playbin.audio_filter = tempo;
            playbin.get_bus().add_watch(Priority.DEFAULT, (bus, message) => {
                if (message.type == Gst.MessageType.EOS) {
                    finish();
                } else if (message.type == Gst.MessageType.ERROR) {
                    Error error;
                    string debug;
                    message.parse_error(out error, out debug);
                    warning("Player: %s", error.message);
                    finish();
                } else if (message.type == Gst.MessageType.DURATION_CHANGED || message.type == Gst.MessageType.ASYNC_DONE) {
                    int64 value = 0;
                    if (((Gst.Element) playbin).query_duration(Gst.Format.TIME, out value) && value > 0) duration = value;
                }
                return true;
            });
        }

        private void finish() {
            playbin.set_state(Gst.State.PAUSED);
            playing = false;
            stop_at = -1;
            seek(0);
            ended();
        }

        public void open(File file, int64 known_duration) {
            playbin.set_state(Gst.State.NULL);
            uri = file.get_uri();
            playbin.uri = uri;
            duration = known_duration;
            playing = false;
            stop_at = -1;
            playbin.set_state(Gst.State.PAUSED);
        }

        public void close() {
            playbin.set_state(Gst.State.NULL);
            playing = false;
            uri = "";
        }

        public int64 position() {
            int64 value = 0;
            if (uri != "" && ((Gst.Element) playbin).query_position(Gst.Format.TIME, out value)) {
                if (stop_at > 0 && value >= stop_at) {
                    playbin.set_state(Gst.State.PAUSED);
                    playing = false;
                    stop_at = -1;
                    ended();
                }
                return value;
            }
            return 0;
        }

        public void play() {
            if (uri == "") return;
            playbin.set_state(Gst.State.PLAYING);
            playing = true;
            if (speed != 1.0) Idle.add(() => {
                apply_rate(position());
                return Source.REMOVE;
            });
        }

        public void play_range(int64 from, int64 to) {
            if (uri == "") return;
            seek(from);
            stop_at = to;
            play();
        }

        public void pause() {
            playbin.set_state(Gst.State.PAUSED);
            playing = false;
            stop_at = -1;
        }

        public void toggle() {
            if (playing) pause();
            else play();
        }

        public void seek(int64 to) {
            if (uri == "") return;
            apply_rate(to.clamp(0, duration > 0 ? duration : to));
        }

        public void seek_when_ready(int64 to) {
            if (uri == "") return;
            Gst.State state, pending;
            playbin.get_state(out state, out pending, 2 * Gst.SECOND);
            seek(to);
        }

        public void change_speed(double value) {
            speed = value;
            apply_rate(position());
        }

        private void apply_rate(int64 at) {
            playbin.seek(speed, Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                Gst.SeekType.SET, at, Gst.SeekType.NONE, -1);
        }
    }
}
