using Gtk;

namespace Singularity.Apps.Voice {

    public enum WaveMode {
        LIVE,
        PLAYBACK,
        TRIM
    }

    public class WaveformView : Widget {
        private const float BAR = 3f;
        private const float GAP = 2f;
        private const float HANDLE = 14f;

        public WaveMode mode { get; set; default = WaveMode.PLAYBACK; }
        public int64 duration { get; set; default = 0; }
        public int64 position { get; set; default = 0; }
        public TrimRange? range { get; set; default = null; }
        public TrimMode trim_mode { get; set; default = TrimMode.KEEP; }

        public signal void seek_requested(int64 position);

        private float[] peaks = {};
        private float[] live = {};
        private int dragging = 0;
        private double drag_from = 0;

        public WaveformView() {
            Object(css_name: "voice-waveform");
        }

        construct {
            add_css_class("voice-waveform");
            focusable = true;
            hexpand = true;
            height_request = 120;
            var style = Singularity.Style.StyleManager.get_default();
            style.notify["accent-hex"].connect(queue_draw);
            notify["position"].connect(queue_draw);
            notify["mode"].connect(queue_draw);
            notify["trim-mode"].connect(queue_draw);
            notify["range"].connect(() => {
                if (range != null) range.changed.connect(queue_draw);
                queue_draw();
            });

            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => begin_drag(x));
            drag.drag_update.connect((dx, dy) => update_drag(drag_from + dx));
            drag.drag_end.connect((dx, dy) => {
                update_drag(drag_from + dx);
                dragging = 0;
            });
            add_controller(drag);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (mode == WaveMode.TRIM && range != null && (keyval == Gdk.Key.Left || keyval == Gdk.Key.Right)) {
                    int64 delta = (keyval == Gdk.Key.Left ? -1 : 1) * NS_PER_SECOND / 2;
                    if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) range.move_end(range.end + delta);
                    else range.move_start(range.start + delta);
                    return true;
                }
                if (mode != WaveMode.PLAYBACK || duration <= 0) return false;
                int64 step = NS_PER_SECOND * 5;
                if (keyval == Gdk.Key.Left) {
                    seek_requested(int64.max(position - step, 0));
                    return true;
                }
                if (keyval == Gdk.Key.Right) {
                    seek_requested(int64.min(position + step, duration));
                    return true;
                }
                return false;
            });
            add_controller(keys);
            update_accessible_state();
        }

        private void update_accessible_state() {
            update_property(Gtk.AccessibleProperty.LABEL, _("Waveform"), -1);
        }

        public void set_peaks(float[] values) {
            peaks = values;
            queue_draw();
        }

        public void reset_live() {
            live = {};
            queue_draw();
        }

        public void push_live(float value) {
            live += value;
            queue_draw();
        }

        private double x_for(int64 time) {
            if (duration <= 0) return 0;
            return (double) time / duration * get_width();
        }

        private int64 time_for(double x) {
            double w = get_width();
            if (w <= 0 || duration <= 0) return 0;
            return (int64) ((x / w).clamp(0, 1) * duration);
        }

        private void begin_drag(double x) {
            drag_from = x;
            grab_focus();
            if (mode == WaveMode.PLAYBACK) {
                dragging = 3;
                seek_requested(time_for(x));
                return;
            }
            if (mode != WaveMode.TRIM || range == null) return;
            double a = x_for(range.start);
            double b = x_for(range.end);
            if (Math.fabs(x - a) <= HANDLE && Math.fabs(x - a) <= Math.fabs(x - b)) dragging = 1;
            else if (Math.fabs(x - b) <= HANDLE) dragging = 2;
            else {
                dragging = 4;
                range.set_fraction(x / get_width(), x / get_width());
            }
        }

        private void update_drag(double x) {
            if (dragging == 3) {
                seek_requested(time_for(x));
            } else if (dragging == 1 && range != null) {
                range.move_start(time_for(x));
            } else if (dragging == 2 && range != null) {
                range.move_end(time_for(x));
            } else if (dragging == 4 && range != null) {
                double w = get_width();
                range.set_fraction(drag_from / w, x / w);
            }
        }

        private static Gdk.RGBA rgba(string hex, float alpha = 1f) {
            var color = Gdk.RGBA();
            color.parse(hex);
            color.alpha = alpha;
            return color;
        }

        private void fill_bars(Gtk.Snapshot snapshot, float[] values, int from, int to, float x0, float mid, float half, Gdk.RGBA color) {
            if (to <= from) return;
            var builder = new Gsk.PathBuilder();
            for (int i = from; i < to; i++) {
                float h = float.max(values[i] * half, 1.5f);
                float x = x0 + i * (BAR + GAP);
                var rect = Graphene.Rect().init(x, mid - h, BAR, h * 2);
                var rounded = Gsk.RoundedRect();
                rounded.init_from_rect(rect, BAR / 2);
                builder.add_rounded_rect(rounded);
            }
            snapshot.append_fill(builder.to_path(), Gsk.FillRule.WINDING, color);
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            float w = get_width();
            float h = get_height();
            if (w <= 0 || h <= 0) return;
            string accent_hex = Singularity.Style.StyleManager.get_default().accent_hex;
            var accent = rgba(accent_hex);
            var fg = get_color();
            var dim = fg;
            dim.alpha = 0.28f;
            float mid = h / 2;
            float half = h / 2 - 6;
            int slots = int.max((int) ((w + GAP) / (BAR + GAP)), 1);

            if (mode == WaveMode.LIVE) {
                int count = int.min(live.length, slots);
                var values = new float[count];
                for (int i = 0; i < count; i++) values[i] = live[live.length - count + i];
                float x0 = w - count * (BAR + GAP) + GAP;
                fill_bars(snapshot, values, 0, count, x0, mid, half, rgba("#e01b24"));
                var line = rgba("#e01b24", 0.5f);
                snapshot.append_color(line, Graphene.Rect().init(w - 2, 4, 2, h - 8));
                if (count < slots) {
                    snapshot.append_color(dim, Graphene.Rect().init(0, mid - 0.5f, x0, 1));
                }
                return;
            }

            var values = Peaks.bucket(peaks, slots);
            float used = slots * (BAR + GAP) - GAP;
            float x0 = (w - used) / 2;
            if (mode == WaveMode.PLAYBACK) {
                int played = duration > 0 ? (int) ((double) position / duration * slots) : 0;
                played = played.clamp(0, slots);
                fill_bars(snapshot, values, 0, played, x0, mid, half, accent);
                fill_bars(snapshot, values, played, slots, x0, mid, half, dim);
                float px = (float) x_for(position);
                snapshot.append_color(accent, Graphene.Rect().init(px.clamp(0, w - 2), 0, 2, h));
                return;
            }

            if (range == null) {
                fill_bars(snapshot, values, 0, slots, x0, mid, half, dim);
                return;
            }
            int a = (int) ((double) range.start / int64.max(duration, 1) * slots);
            int b = (int) ((double) range.end / int64.max(duration, 1) * slots);
            a = a.clamp(0, slots);
            b = b.clamp(a, slots);
            bool keep = trim_mode == TrimMode.KEEP;
            fill_bars(snapshot, values, 0, a, x0, mid, half, keep ? dim : accent);
            fill_bars(snapshot, values, a, b, x0, mid, half, keep ? accent : rgba("#e01b24", 0.55f));
            fill_bars(snapshot, values, b, slots, x0, mid, half, keep ? dim : accent);
            float xa = (float) x_for(range.start);
            float xb = (float) x_for(range.end);
            var band = keep ? rgba(accent_hex, 0.12f) : rgba("#e01b24", 0.10f);
            snapshot.append_color(band, Graphene.Rect().init(xa, 0, xb - xa, h));
            var handle_color = keep ? accent : rgba("#e01b24");
            foreach (float x in new float[] { xa, xb }) {
                float cx = x.clamp(8, w - 8);
                snapshot.append_color(handle_color, Graphene.Rect().init(cx - 1.5f, 0, 3, h));
                var rim = Gsk.RoundedRect();
                rim.init_from_rect(Graphene.Rect().init(cx - 8, mid - 16, 16, 32), 8);
                snapshot.push_rounded_clip(rim);
                snapshot.append_color(rgba("#ffffff"), rim.bounds);
                snapshot.pop();
                var knob = Gsk.RoundedRect();
                knob.init_from_rect(Graphene.Rect().init(cx - 6, mid - 14, 12, 28), 6);
                snapshot.push_rounded_clip(knob);
                snapshot.append_color(handle_color, knob.bounds);
                snapshot.pop();
            }
            if (position > 0) {
                float px = (float) x_for(position);
                snapshot.append_color(fg, Graphene.Rect().init(px.clamp(0, w - 1), 0, 1, h));
            }
        }
    }
}
